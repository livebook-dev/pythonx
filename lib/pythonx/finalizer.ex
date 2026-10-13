defmodule Pythonx.Finalizer do
  @moduledoc false

  # Finalizer is a GenServer that finalizes the Python interpreter when the
  # application stops. Placed after Janitor and ObjectTracker in the
  # supervision tree, so it is stopped first (reverse order).
  #
  # Its terminate/3 callback calls Pythonx.__finalize__/0 (the unguarded
  # internal function). The finalize NIF sends :finalizing to the Janitor
  # before waiting for in-flight threads, and :finalized after Py_FinalizeEx
  # completes, before releasing init_mutex.
  #
  # This way the Janitor coordination works regardless of whether finalize is
  # called from this GenServer or directly.
  #
  # The finalize NIF itself runs on a dirty scheduler, but Py_FinalizeEx does
  # not: CPython requires it on the thread that ran Py_InitializeEx, so the
  # NIF hands both calls to a native thread pythonx owns (the one Python sees
  # as threading.main_thread()) and joins it once finalization is done. This
  # GenServer does not need to know which thread it is running on.

  use GenServer

  require Logger

  @name __MODULE__

  @binaries Application.compile_env(:pythonx, :binaries, :fast)
  @finalization Application.compile_env(:pythonx, :finalization, true)

  # Py_FinalizeEx runs atexit handlers and module teardown of arbitrary
  # duration (a loaded ML framework can take well over the 5s default).
  # If the supervisor gave up early, the NIF would keep running on its
  # dirty scheduler while the rest of the tree, including the Janitor,
  # is torn down and the VM halts underneath it. Wait for it; bounding
  # shutdown time is the job of whatever supervises the OS process.
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      shutdown: :infinity
    }
  end

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: @name)
  end

  @impl true
  def init(:ok) do
    # trap_exit must be true for terminate/3 to be called when the
    # supervisor stops this child.
    Process.flag(:trap_exit, true)
    {:ok, :ok}
  end

  @impl true
  def terminate(_reason, _state) do
    # Tell the Janitor to skip decref calls during finalization.
    # Messages are delivered in order, so any decref messages
    # already in the mailbox are processed normally before this.
    send(Pythonx.Janitor, :finalizing)

    # Ping the Janitor to flush all pending messages (including any
    # decref calls) before we finalize. This ensures no decref NIF
    # is blocked on the GIL when Py_FinalizeEx destroys it.
    Pythonx.Janitor.ping()

    # Finalize the Python interpreter. The NIF sends :finalized to
    # the Janitor after Py_FinalizeEx completes, before releasing
    # init_mutex. We call __finalize__/0 (the unguarded internal
    # function) because the public finalize/0 refuses to run while
    # the app is running.
    #
    # After __finalize__/0, if binaries == :fast and finalization is
    # true, check the resource count (returned from the finalize NIF)
    # and log a warning if non-zero.
    case Pythonx.__finalize__() do
      :ok ->
        :ok

      {:error, %Pythonx.FinalizeError{return_code: return_code, resource_count: count}} ->
        if @binaries == :fast and @finalization and count > 0 do
          Logger.warning(
            "Pythonx: Py_FinalizeEx (exit code #{return_code}) left #{count} " <>
              "PyObjectResource instances alive. With :fast binaries, " <>
              "resource-backed binaries may reference freed Python memory."
          )
        else
          Logger.warning("Pythonx: Py_FinalizeEx returned exit code #{return_code}")
        end

        :ok
    end
  end
end
