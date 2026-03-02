defmodule Pythonx.ObjectTracker do
  @moduledoc false

  # Tracks objects that other nodes point to, effectively implementing
  # distributed garbage collection.
  #
  # Each Pythonx object uses a NIF resource, which resides in the
  # memory of the node where it was created (owner). Such object can
  # be sent to another node (peer), however once the owner node has
  # no more references to the resource, it gets garbage collected. If
  # the peer node does another RPC to operate on the object, it will
  # fail, as the resource no longer exists. To address this, the owner
  # node needs to keep the resource reference around, as long as any
  # peer node points to it. This is precisely what this process does.
  #
  # We don't know when an object is sent to a peer node, so the peer
  # node needs to explicitly request for the object to be tracked by
  # calling `track_remote_object/1`. Tracking an object has two main
  # parts:
  #
  #   1. The resource reference is stored in the ObjectTracker
  #      process on the owner node, preventing the object form being
  #      garbage collected.
  #
  #   2. The peer node creates a local garbage collection notifier
  #      and stores it in the local `%Pythonx.Object{}`. Once that
  #      local struct is garbage collected, the notifier sends a
  #      message and eventually the reference from point 1. is removed.
  #
  # Note that for this to work correctly, the object must be kept
  # alive on the owner node, until the peer calls `track_remote_object/1`.
  # This, for example, is guaranteed in FLAME when implementing the
  # FLAME.Trackable protocol.

  use GenServer

  @name __MODULE__

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: @name)
  end

  @doc """
  An identity function to prevent GC.
  """
  @spec identity(term()) :: term()
  def identity(data), do: data

  @doc """
  Locates the ObjectTracker process.
  """
  @spec whereis!() :: pid()
  def whereis!() do
    Process.whereis(@name) || exit({:noproc, {__MODULE__, :whereis!, []}})
  end

  @doc """
  Starts tracking a remote object, to prevent it from being garbage
  collected.

  If the object is local, or already tracked locally, it is returned
  as is.

  Returns an updated object and a marker PID. The marker is a dummy
  process that stays alive as long as the object's owner node tracks
  any references. The marker is specifically designed for implementing
  `FLAME.Trackable`, and can be ignored otherwise.
  """
  @spec track_remote_object(Pythonx.Object.t()) ::
          {:ok, Pythonx.Object.t(), pid()} | {:noop, Pythonx.Object.t()}
  def track_remote_object(%Pythonx.Object{resource: ref} = object)
      when node(ref) == node() do
    # Local object.
    {:noop, object}
  end

  def track_remote_object(%Pythonx.Object{remote_info: gc_notifier} = object)
      when node(gc_notifier) == node() do
    # Already tracked by this node.
    {:noop, object}
  end

  def track_remote_object(%Pythonx.Object{resource: remote_ref} = object) do
    local_pid = whereis!()
    remote_pid = :erpc.call(node(remote_ref), __MODULE__, :whereis!, [])
    gc_notifier = Pythonx.NIF.create_gc_notifier(local_pid, {:local_gc, remote_pid, remote_ref})
    marker_pid = GenServer.call(remote_pid, {:track, remote_ref, local_pid}, :infinity)
    object = %{object | remote_info: gc_notifier}
    {:ok, object, marker_pid}
  end

  @impl true
  def init(:ok) do
    {:ok, %{pid_refs: %{}, pid_monitors: %{}, marker_pid: nil}}
  end

  @impl true
  def handle_call({:track, ref, pid}, _from, state) do
    pid_monitors = Map.put_new_lazy(state.pid_monitors, pid, fn -> Process.monitor(pid) end)
    pid_refs = add_ref(state.pid_refs, pid, ref)
    state = ensure_marker(state)
    {:reply, state.marker_pid, %{state | pid_refs: pid_refs, pid_monitors: pid_monitors}}
  end

  @impl true
  def handle_continue(:gc, state) do
    :erlang.garbage_collect()
    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    state = %{
      state
      | pid_refs: Map.delete(state.pid_refs, pid),
        pid_monitors: Map.delete(state.pid_monitors, pid)
    }

    state = maybe_stop_marker(state)
    {:noreply, state, {:continue, :gc}}
  end

  def handle_info({:untrack, ref, pid}, state) do
    pid_refs = remove_ref(state.pid_refs, pid, ref)

    state =
      if Map.fetch!(pid_refs, pid) == %{} do
        Process.demonitor(state.pid_monitors[pid], [:flush])

        %{
          state
          | pid_monitors: Map.delete(state.pid_monitors, pid),
            pid_refs: Map.delete(pid_refs, pid)
        }
      else
        %{state | pid_refs: pid_refs}
      end

    state = maybe_stop_marker(state)
    {:noreply, state, {:continue, :gc}}
  end

  def handle_info({:local_gc, remote_pid, remote_ref}, state) do
    send(remote_pid, {:untrack, remote_ref, self()})
    {:noreply, state}
  end

  defp ensure_marker(%{marker_pid: nil} = state) do
    pid =
      spawn_link(fn ->
        receive do
          :stop -> :ok
        end
      end)

    %{state | marker_pid: pid}
  end

  defp ensure_marker(state), do: state

  defp maybe_stop_marker(state) when state.marker_pid != nil and state.pid_refs == %{} do
    send(state.marker_pid, :stop)
    %{state | marker_pid: nil}
  end

  defp maybe_stop_marker(state), do: state

  defp add_ref(pid_refs, pid, ref) do
    case pid_refs do
      %{^pid => %{^ref => count} = refs} ->
        %{pid_refs | pid => %{refs | ref => count + 1}}

      %{^pid => refs} ->
        %{pid_refs | pid => Map.put(refs, ref, 1)}

      %{} ->
        Map.put(pid_refs, pid, %{ref => 1})
    end
  end

  defp remove_ref(pid_refs, pid, ref) do
    case pid_refs do
      %{^pid => %{^ref => 1} = refs} ->
        %{pid_refs | pid => Map.delete(refs, ref)}

      %{^pid => %{^ref => count} = refs} ->
        %{pid_refs | pid => %{refs | ref => count - 1}}

      %{} ->
        pid_refs
    end
  end
end

if Code.ensure_loaded?(FLAME.Trackable) do
  defimpl FLAME.Trackable, for: [Pythonx.Object] do
    def track(object, acc, _node) do
      case Pythonx.ObjectTracker.track_remote_object(object) do
        {:noop, object} -> {object, acc}
        {:ok, object, marker_pid} -> {object, [marker_pid | acc]}
      end
    end
  end
end
