defmodule Pythonx.FinalizeTest do
  # These tests cannot be async because they tear down and re-initialize
  # the global Python interpreter.
  use ExUnit.Case, async: false

  # The test_helper.exs initializes the interpreter before tests run.
  # After each test that calls __finalize__/0, we re-initialize so that
  # subsequent tests (including async ones) have a working interpreter.
  # We use __finalize__/0 (the unguarded internal function) because
  # the public finalize/0 refuses to run while the app is running.

  @pyproject """
  [project]
  name = "project"
  version = "0.0.0"
  requires-python = "==3.13.*"
  dependencies = [
    "numpy==2.1.2",
    "cloudpickle==3.1.2"
  ]
  """

  defp reinit! do
    Pythonx.uv_init(@pyproject)
  end

  # Helper that mirrors what Pythonx.Finalizer does: flush the Janitor
  # before finalizing, so no decref NIF is blocked on the GIL when
  # Py_FinalizeEx destroys it. We also force GC so that PyObjectResource
  # instances are collected before finalization, keeping resource_count
  # at zero (which matters when binaries is :fast).
  defp finalize! do
    :erlang.garbage_collect()
    send(Pythonx.Janitor, :finalizing)
    Pythonx.Janitor.ping()
    Pythonx.__finalize__()
  end

  describe "finalize/0" do
    test "refuses to run while the application is running" do
      assert_raise RuntimeError,
                   ~r/cannot be called while the :pythonx application is running/,
                   fn ->
                     Pythonx.finalize()
                   end
    end

    test "returns :ok after initialization" do
      assert finalize!() == :ok
      reinit!()
    end

    test "is idempotent (second call is a no-op)" do
      finalize!()
      assert finalize!() == :ok
      reinit!()
    end

    test "is a no-op when never initialized" do
      # The interpreter is currently initialized (by test_helper).
      # Finalize, then finalize again (already not initialized).
      finalize!()
      assert finalize!() == :ok
      reinit!()
    end

    test "eval raises after finalize" do
      finalize!()

      assert_raise RuntimeError, ~r/Python interpreter has not been initialized/, fn ->
        Pythonx.eval("1 + 1", %{})
      end

      reinit!()
    end

    test "re-initialization works after finalize" do
      finalize!()
      reinit!()

      {result, _} = Pythonx.eval("1 + 1", %{})
      assert Pythonx.decode(result) == 2
    end

    test "multiple finalize/reinit cycles work" do
      for i <- 1..3 do
        finalize!()
        reinit!()

        {result, _} = Pythonx.eval("#{i} + #{i}", %{})
        assert Pythonx.decode(result) == i * 2
      end
    end

    test "finalizes after evals spread across many dirty schedulers" do
      # Regression test for a segfault in Py_FinalizeEx. Concurrent
      # evals make several dirty scheduler threads create their own
      # Python thread state. Finalize then lands on an arbitrary
      # dirty scheduler. CPython requires Py_FinalizeEx to run on the
      # thread that ran Py_InitializeEx; when it did not, CPython 3.13
      # freed the calling thread's state and dereferenced it while
      # flushing std files. Deterministic on any machine with more
      # than one dirty CPU scheduler.
      n = System.schedulers_online() * 4

      for cycle <- 1..3 do
        results =
          1..n
          |> Task.async_stream(
            fn i ->
              {result, _} =
                Pythonx.eval(
                  """
                  import time
                  time.sleep(0.05)
                  #{i} * #{cycle}
                  """,
                  %{}
                )

              Pythonx.decode(result)
            end,
            max_concurrency: n,
            timeout: 30_000
          )
          |> Enum.map(fn {:ok, value} -> value end)

        assert results == Enum.map(1..n, &(&1 * cycle))

        assert finalize!() == :ok
        reinit!()
      end

      {result, _} = Pythonx.eval("1 + 1", %{})
      assert Pythonx.decode(result) == 2
    end

    test "pure-Python stdlib works after re-initialization" do
      # Confirms that core and stdlib re-init is clean under the fresh
      # main thread: imports, a real OS thread started from Python,
      # and atexit registration observed on the second finalize.
      finalize!()
      reinit!()

      tmp_path =
        System.tmp_dir!()
        |> Path.join("pythonx_reinit_test_#{:erlang.unique_integer([:positive])}.txt")

      File.rm(tmp_path)

      {result, _} =
        Pythonx.eval(
          """
          import atexit
          import json
          import logging
          import threading

          logging.getLogger("pythonx_reinit").info("still works")

          seen = []

          def work():
            seen.append(threading.current_thread().name)

          thread = threading.Thread(target=work, name="pythonx-reinit-worker")
          thread.start()
          thread.join()

          atexit.register(lambda: open("#{tmp_path}", "w").write("second finalize"))

          json.dumps({"seen": seen, "main": threading.main_thread().name})
          """,
          %{}
        )

      assert Pythonx.decode(result) ==
               ~s({"seen": ["pythonx-reinit-worker"], "main": "MainThread"})

      assert finalize!() == :ok
      assert File.read!(tmp_path) == "second finalize"
      File.rm(tmp_path)

      reinit!()
    end

    test "atexit handlers run during finalization" do
      # Register an atexit handler that writes to a module-level
      # variable. After finalize + re-init, we can't read the old
      # module state, so instead we verify via a side effect:
      # the handler creates a file that we can check from Elixir.
      tmp_path =
        System.tmp_dir!()
        |> Path.join("pythonx_atexit_test_#{:erlang.unique_integer([:positive])}.txt")

      File.rm(tmp_path)

      Pythonx.eval(
        """
        import atexit
        atexit.register(lambda: open("#{tmp_path}", "w").write("done"))
        """,
        %{}
      )

      assert finalize!() == :ok
      # Py_FinalizeEx calls atexit handlers, which should create the file.
      assert File.exists?(tmp_path)
      assert File.read!(tmp_path) == "done"
      File.rm(tmp_path)

      reinit!()
    end

    test "logging shutdown runs during finalization" do
      # logging registers atexit.register(shutdown), which flushes
      # and closes all handlers. We verify by writing to a temp file
      # via a logging handler, then checking the file content after
      # finalization.
      tmp_path =
        System.tmp_dir!()
        |> Path.join("pythonx_logging_test_#{:erlang.unique_integer([:positive])}.log")

      File.rm(tmp_path)

      Pythonx.eval(
        """
        import logging
        handler = logging.FileHandler("#{tmp_path}")
        handler.setFormatter(logging.Formatter("%(message)s"))
        logger = logging.getLogger("pythonx_test")
        logger.addHandler(handler)
        logger.setLevel(logging.INFO)
        logger.info("hello from logging")
        """,
        %{}
      )

      assert finalize!() == :ok
      # The atexit handler for logging should have flushed the message.
      assert File.exists?(tmp_path)
      assert File.read!(tmp_path) =~ "hello from logging"
      File.rm(tmp_path)

      reinit!()
    end
  end

  describe "generation guard" do
    test "prevents stale objects from being decoded after re-init" do
      {_result, globals} = Pythonx.eval("x = [1, 2, 3]", %{})
      {result, _} = Pythonx.eval("x", globals)
      assert Pythonx.decode(result) == [1, 2, 3]

      finalize!()
      reinit!()

      assert_raise RuntimeError,
                   ~r/Pythonx object is from a previous interpreter generation/,
                   fn -> Pythonx.decode(result) end
    end

    test "prevents eval of stale globals after re-init" do
      {_result, globals} = Pythonx.eval("x = [1, 2, 3]", %{})

      finalize!()
      reinit!()

      assert_raise RuntimeError,
                   ~r/Pythonx object is from a previous interpreter generation/,
                   fn -> Pythonx.eval("x", globals) end
    end

    test "doesn't affect fresh objects after re-init" do
      finalize!()
      reinit!()

      {result, globals} = Pythonx.eval("x = 42\nx", %{})
      assert Pythonx.decode(result) == 42

      {result2, _} = Pythonx.eval("x", globals)
      assert Pythonx.decode(result2) == 42
    end

    test "prevents repr of stale objects after re-init" do
      {result, _} = Pythonx.eval("[1, 2, 3]", %{})

      finalize!()
      reinit!()

      assert_raise RuntimeError,
                   ~r/Pythonx object is from a previous interpreter generation/,
                   fn -> Inspect.Pythonx.Object.__repr_string__(result) end
    end

    test "prevents dump of stale objects after re-init" do
      {result, _} = Pythonx.eval("[1, 2, 3]", %{})

      finalize!()
      reinit!()

      # __dump__ catches exceptions and returns {:error, ...}
      assert {:error, %RuntimeError{message: msg}} = Pythonx.__dump__(result)
      assert msg =~ "Pythonx object is from a previous interpreter generation"
    end
  end

  describe "concurrent finalize" do
    test "waits for in-flight eval to complete" do
      # This test verifies that finalize() waits for an in-flight eval
      # to complete before tearing down the interpreter.
      #
      # The runner evals a 0.3s sleep. After 100ms, we call finalize.
      # finalize must wait for the runner's eval NIF to finish (via
      # the ActiveThreadGuard) before calling Py_FinalizeEx.
      #
      # The runner's eval returns a result, but calling decode on it
      # after finalization would fail (interpreter is gone), so we
      # only check that eval itself completed without error.
      runner =
        Task.async(fn ->
          {result, _} =
            Pythonx.eval(
              """
              import time
              time.sleep(0.3)
              42
              """,
              %{}
            )

          # Return the result struct (not decoded — interpreter
          # may be torn down by the time we get here)
          result
        end)

      Process.sleep(100)

      # The runner holds a Pythonx.Object, so resource_count will be
      # non-zero. With :fast binaries this triggers a FinalizeError.
      # We accept either :ok or an error with return_code 0 — the
      # important thing is that finalize waited for the runner.
      case finalize!() do
        :ok -> :ok
        {:error, %Pythonx.FinalizeError{return_code: 0}} -> :ok
      end

      # The runner should have completed successfully. The eval NIF
      # ran time.sleep(0.3) and returned before finalize destroyed
      # the interpreter. The result is a Pythonx.Object struct.
      assert Task.await(runner, 5000)

      reinit!()
    end
  end

  describe "Janitor :finalizing/:finalized" do
    test "Janitor skips decref during finalization" do
      # Create some Python objects that will be garbage collected
      {_result, _globals} = Pythonx.eval("x = [1, 2, 3]", %{})

      # Tell the Janitor we're finalizing
      send(Pythonx.Janitor, :finalizing)

      # Trigger GC — destructors will send decref messages,
      # but the Janitor should skip them
      :erlang.garbage_collect()

      # Give the Janitor time to process messages
      Pythonx.Janitor.ping()

      # Tell the Janitor finalization is done
      send(Pythonx.Janitor, :finalized)

      # Janitor should be back to normal
      assert Pythonx.Janitor.ping() == :pong
    end

    test "Janitor resumes decref after :finalized" do
      # Create a Python object, then tell the Janitor we're finalizing.
      # GC while finalizing — decref is skipped. Then tell the Janitor
      # we're done finalizing. GC again — decref should now work.
      {result, _} = Pythonx.eval("[1, 2, 3]", %{})

      send(Pythonx.Janitor, :finalizing)
      :erlang.garbage_collect()
      Pythonx.Janitor.ping()

      # Now resume normal operation
      send(Pythonx.Janitor, :finalized)
      assert Pythonx.Janitor.ping() == :pong

      # Let the object go and trigger GC — the Janitor should
      # process the decref normally now (no error, no crash)
      _ = result
      :erlang.garbage_collect()
      Pythonx.Janitor.ping()
      assert Pythonx.Janitor.ping() == :pong
    end

    test "Janitor forwards output during finalization" do
      # Output should be forwarded even when finalizing, since
      # Py_FinalizeEx may flush stdout from module finalizers.
      test_pid = self()

      # Create a simple IO device that forwards io_request messages
      # to the test process so we can assert on them.
      io_pid =
        spawn(fn ->
          receive do
            {:io_request, from, reply_as, {:put_chars, :unicode, output}} ->
              send(test_pid, {:output_received, output})
              send(from, {:io_reply, reply_as, :ok})
          end
        end)

      send(Pythonx.Janitor, :finalizing)

      # Simulate output from a Python finalizer
      send(Pythonx.Janitor, {:output, "hello from finalizer", io_pid})

      Pythonx.Janitor.ping()

      # The output should have been forwarded to the IO device
      assert_received {:output_received, "hello from finalizer"}

      send(Pythonx.Janitor, :finalized)
    end
  end
end
