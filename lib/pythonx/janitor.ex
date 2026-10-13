defmodule Pythonx.Janitor do
  @moduledoc false

  # Janitor is a single named process that handles messages sent from
  # NIF calls.

  use GenServer

  @name __MODULE__

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, {}, name: @name)
  end

  @doc """
  Sends a ping message and waits for the reply.
  """
  @spec ping() :: :pong
  def ping() do
    GenServer.call(@name, :ping)
  end

  @impl true
  def init({}) do
    {:ok, %{finalizing: false}}
  end

  @impl true
  def handle_call(:ping, _from, state) do
    {:reply, :pong, state}
  end

  @impl true
  def handle_info(:finalizing, state) do
    # Finalization is starting. Skip decref calls from now on —
    # Py_FinalizeEx will free all Python objects regardless.
    # Output messages are still forwarded normally.
    {:noreply, %{state | finalizing: true}}
  end

  def handle_info(:finalized, state) do
    # Finalization is complete. Resume normal decref handling.
    {:noreply, %{state | finalizing: false}}
  end

  def handle_info({:decref, ptr}, state) do
    # After %Pythonx.Object{} is garbage collected, the C++ code
    # sends us a message to decrement refcount of the corresponding
    # Python object in a separate NIF call. For more details see
    # ExObjectResource::destructor in the C++ code.
    #
    # Skip during finalization — Py_FinalizeEx frees everything.
    unless state.finalizing do
      Pythonx.NIF.janitor_decref(ptr)
    end

    {:noreply, state}
  end

  def handle_info({:output, output, device}, state) do
    # We send the IO request and continue without waiting for the IO
    # reply. Output is forwarded even during finalization, since
    # Py_FinalizeEx may flush stdout/stderr from module finalizers.
    send(device, {:io_request, self(), make_ref(), {:put_chars, :unicode, output}})
    {:noreply, state}
  end

  def handle_info({:io_reply, _reply_as, _reply}, state) do
    {:noreply, state}
  end
end
