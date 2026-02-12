defmodule PythonxTest do
  use ExUnit.Case, async: true

  doctest Pythonx

  describe "encode!/1" do
    test "atom" do
      assert repr(Pythonx.encode!(nil)) == "None"
      assert repr(Pythonx.encode!(false)) == "False"
      assert repr(Pythonx.encode!(true)) == "True"
      assert repr(Pythonx.encode!(:hello)) == "'hello'"
    end

    test "integer" do
      assert repr(Pythonx.encode!(10)) == "10"
      assert repr(Pythonx.encode!(-10)) == "-10"

      # Large numbers (over 64 bits)
      assert repr(Pythonx.encode!(2 ** 100)) == "1267650600228229401496703205376"
    end

    test "float" do
      assert repr(Pythonx.encode!(10.5)) == "10.5"
      assert repr(Pythonx.encode!(-10.5)) == "-10.5"
    end

    test "string" do
      assert repr(Pythonx.encode!("hello")) == "b'hello'"

      assert repr(Pythonx.encode!("🦊 in a 📦")) ==
               ~S"b'\xf0\x9f\xa6\x8a in a \xf0\x9f\x93\xa6'"
    end

    test "binary" do
      assert repr(Pythonx.encode!(<<65, 255>>)) == ~S"b'A\xff'"

      assert_raise Protocol.UndefinedError, fn ->
        Pythonx.encode!(<<1::4>>)
      end
    end

    test "list" do
      assert repr(Pythonx.encode!([])) == "[]"
      assert repr(Pythonx.encode!([1, 2.0, "hello"])) == "[1, 2.0, b'hello']"
    end

    test "tuple" do
      assert repr(Pythonx.encode!({})) == "()"
      assert repr(Pythonx.encode!({1})) == "(1,)"
      assert repr(Pythonx.encode!({1, 2.0, "hello"})) == "(1, 2.0, b'hello')"
    end

    test "map" do
      assert repr(Pythonx.encode!(%{"hello" => 1})) == "{b'hello': 1}"
      assert repr(Pythonx.encode!(%{2 => nil})) == "{2: None}"
    end

    test "mapset" do
      assert repr(Pythonx.encode!(MapSet.new([1]))) == "{1}"
    end

    test "pid" do
      assert repr(Pythonx.encode!(IEx.Helpers.pid(0, 1, 2))) == "<pythonx.PID>"
    end

    test "identity for Pythonx.Object" do
      object = Pythonx.encode!(1)
      assert Pythonx.encode!(object) == object
    end

    test "custom encoder" do
      # Contrived example where we encode tuples as lists.

      encoder = fn
        tuple, encoder when is_tuple(tuple) ->
          Pythonx.Encoder.encode(Tuple.to_list(tuple), encoder)

        other, encoder ->
          Pythonx.Encoder.encode(other, encoder)
      end

      assert repr(Pythonx.encode!({1, 2}, encoder)) == "[1, 2]"
    end
  end

  describe "decode/1" do
    test "none" do
      assert Pythonx.decode(eval_result("None")) == nil
    end

    test "boolean" do
      assert Pythonx.decode(eval_result("True")) == true
      assert Pythonx.decode(eval_result("False")) == false
    end

    test "integer" do
      assert Pythonx.decode(eval_result("10")) == 10
      assert Pythonx.decode(eval_result("-10")) == -10

      # Large numbers (over 64 bits)
      assert Pythonx.decode(eval_result("2 ** 100")) == 1_267_650_600_228_229_401_496_703_205_376
    end

    test "float" do
      assert Pythonx.decode(eval_result("10.5")) == 10.5
      assert Pythonx.decode(eval_result("-10.5")) == -10.5
    end

    test "string" do
      assert Pythonx.decode(eval_result("'hello'")) == "hello"
      assert Pythonx.decode(eval_result("'🦊 in a 🎁'")) == "🦊 in a 🎁"
    end

    test "bytes" do
      assert Pythonx.decode(eval_result(~S"b'A\xff'")) == <<65, 255>>
    end

    test "list" do
      assert Pythonx.decode(eval_result("[]")) == []
      assert Pythonx.decode(eval_result("[1, 2.0, 'hello']")) == [1, 2.0, "hello"]
    end

    test "tuple" do
      assert Pythonx.decode(eval_result("()")) == {}
      assert Pythonx.decode(eval_result("(1,)")) == {1}
      assert Pythonx.decode(eval_result("(1, 2.0, 'hello')")) == {1, 2.0, "hello"}
    end

    test "map" do
      assert Pythonx.decode(eval_result("{'hello': 1}")) == %{"hello" => 1}
      assert Pythonx.decode(eval_result("{2: None}")) == %{2 => nil}
    end

    test "mapset" do
      assert Pythonx.decode(eval_result("set({1})")) == MapSet.new([1])
      assert Pythonx.decode(eval_result("frozenset({1})")) == MapSet.new([1])
    end

    test "pid" do
      pid = IEx.Helpers.pid(0, 1, 2)
      assert {result, %{}} = Pythonx.eval("pid", %{"pid" => pid})
      assert Pythonx.decode(result) == pid
    end

    test "identity for other objects" do
      assert repr(Pythonx.decode(eval_result("complex(1)"))) == "(1+0j)"
    end
  end

  describe "eval/2" do
    test "evaluates a single expression" do
      assert {result, %{}} = Pythonx.eval("1 + 1", %{})
      assert repr(result) == "2"
    end

    test "evaluates multiple statements" do
      assert {result, %{"nums" => nums, "sum" => sum}} =
               Pythonx.eval(
                 """
                 nums = [1, 2, 3]
                 sum = 0
                 for num in nums:
                   sum += num
                 """,
                 %{}
               )

      assert result == nil
      assert repr(nums) == "[1, 2, 3]"
      assert repr(sum) == "6"
    end

    test "returns the result of last expression" do
      assert {result, %{"x" => %Pythonx.Object{}, "y" => %Pythonx.Object{}}} =
               Pythonx.eval(
                 """
                 x = 1
                 y = 1
                 x + y
                 """,
                 %{}
               )

      assert repr(result) == "2"
    end

    test "returns nil for empty code" do
      assert {result, %{}} = Pythonx.eval("", %{})
      assert result == nil

      assert {result, %{}} = Pythonx.eval("# Comment", %{})
      assert result == nil
    end

    test "encodes terms given as globals" do
      assert {result, %{"x" => x, "y" => y, "z" => z}} =
               Pythonx.eval(
                 """
                 z = 3
                 x + y + z
                 """,
                 %{"x" => 1, "y" => 2}
               )

      assert repr(result) == "6"
      assert repr(x) == "1"
      assert repr(y) == "2"
      assert repr(z) == "3"
    end

    test "does not leak globals across evaluations" do
      assert {_result, globals} = Pythonx.eval("x = 1", %{})
      assert Map.keys(globals) == ["x"]

      assert {_result, globals} = Pythonx.eval("y = 1", %{})
      assert Map.keys(globals) == ["y"]
    end

    test "propagates exceptions" do
      assert_raise Pythonx.Error, ~r/NameError: name 'x' is not defined/, fn ->
        Pythonx.eval("x", %{})
      end
    end

    test "with external package" do
      # Note that we install numpy in test_helper.exs. It is a good
      # integration test to make sure the numpy C extension works
      # correctly with the dynamically loaded libpython.

      assert {result, %{"np" => %Pythonx.Object{}}} =
               Pythonx.eval(
                 """
                 import numpy as np
                 np.array([1, 2, 3]) * np.array(10)
                 """,
                 %{}
               )

      assert repr(result) == "array([10, 20, 30])"
    end

    test "sends standard output to caller's group leader" do
      assert ExUnit.CaptureIO.capture_io(fn ->
               Pythonx.eval(
                 """
                 print("hello from Python")
                 """,
                 %{}
               )
             end) == "hello from Python\n"

      # Python thread spawned by the evaluation
      assert ExUnit.CaptureIO.capture_io(fn ->
               Pythonx.eval(
                 """
                 import threading

                 def run():
                   print("hello from thread")

                 thread = threading.Thread(target=run)
                 thread.start()
                 thread.join()
                 """,
                 %{}
               )
             end) == "hello from thread\n"
    end

    test "sends standard error to caller's group leader" do
      assert ExUnit.CaptureIO.capture_io(:stderr, fn ->
               Pythonx.eval(
                 """
                 import sys
                 print("error from Python", file=sys.stderr)
                 """,
                 %{}
               )
             end) =~ "error from Python\n"
    end

    test "sends standard output and error to custom processes when specified" do
      {:ok, io} = StringIO.open("")

      Pythonx.eval(
        """
        import sys
        import threading

        print("hello from Python")
        print("error from Python", file=sys.stderr)

        def run():
          print("hello from thread")

        thread = threading.Thread(target=run)
        thread.start()
        thread.join()
        """,
        %{},
        stdout_device: io,
        stderr_device: io
      )

      {:ok, {_, output}} = StringIO.close(io)

      assert output =~ "hello from Python"
      assert output =~ "error from Python"
      assert output =~ "hello from thread"
    end

    test "raises Python error on stdin attempt" do
      assert_raise Pythonx.Error, ~r/RuntimeError: stdin not supported/, fn ->
        Pythonx.eval(
          """
          input()
          """,
          %{}
        )
      end
    end
  end

  describe "sigil_PY/2" do
    # Note that we evaluate code so that sigil expansion happens at
    # test runtime. This also allows us to control binding precisely.
    #
    # Tests for different Python constructs are in Pythonx.ASTTest,
    # here we only verify the macro behaviour.

    test "defines Elixir variables corresponding to newly defined globals" do
      {_result, binding} =
        Code.eval_string(~S'''
        import Pythonx

        ~PY"""
        x = 1
        """
        ''')

      assert [x: %Pythonx.Object{}] = binding
    end

    test "defines Elixir variables for both conditional branches" do
      # Python allows for defining different variables in conditional
      # branches, but we need to generate the assignments at compile
      # time, so we generate them for all variables. Variables from
      # the skipped branches get assigned nil.

      {_result, binding} =
        Code.eval_string(~S'''
        import Pythonx

        ~PY"""
        if True:
          x = 1
        else:
          y = 2
        """
        ''')

      assert %Pythonx.Object{} = binding[:x]
      assert binding[:y] == nil
    end

    test "passes referenced global variables from Elixir binding" do
      code =
        ~S'''
        import Pythonx

        ~PY"""
        x + 1
        """
        '''

      quoted = Code.string_to_quoted!(code)
      binding = [x: 1, unused: 1]
      env = Code.env_for_eval([])

      {_result, binding, _env} =
        Code.eval_quoted_with_env(quoted, binding, env, prune_binding: true)

      # Verify that :unused was not used (therefore pruned from binding).
      assert Keyword.keys(binding) == [:x]
    end

    test "results in a Python error when a variable is undefined" do
      assert_raise Pythonx.Error, ~r/NameError: name 'x' is not defined/, fn ->
        Code.eval_string(
          ~S'''
          import Pythonx

          ~PY"""
          x + 1
          """
          ''',
          []
        )
      end
    end

    test "global redefinition" do
      {_result, binding} =
        Code.eval_string(
          ~S'''
          import Pythonx

          ~PY"""
          x = x + 1
          """
          ''',
          x: 1
        )

      assert [x: %Pythonx.Object{} = x] = binding

      assert repr(x) == "2"
    end

    test "supports uppercase variables" do
      # Uppercase variables cannot be defined directly in Elixir,
      # however macros can do that by building AST by hand.

      {result, binding} =
        Code.eval_string(~S'''
        import Pythonx

        ~PY"""
        ANSWER = 42
        """

        ~PY"""
        ANSWER + 1
        """
        ''')

      assert [ANSWER: %Pythonx.Object{}] = binding

      assert repr(result) == "43"
    end

    test "does not result in unused variables diagnostics" do
      {_result, diagnostics} =
        Code.with_diagnostics(fn ->
          Code.eval_string(~s'''
          defmodule TestModule#{System.unique_integer([:positive])} do
            import Pythonx

            def run() do
              ~PY"""
              x = 1
              """
            end
          end
          ''')
        end)

      assert diagnostics == []
    end
  end

  describe "python API" do
    test "pythonx.send sends message to the given pid" do
      pid = self()

      assert {_result, %{}} =
               Pythonx.eval(
                 """
                 import pythonx
                 pythonx.send_tagged_object(pid, "message_from_python", ("hello", 1))
                 """,
                 %{"pid" => pid}
               )

      assert_receive {:message_from_python, %Pythonx.Object{} = object}
      assert repr(object) == "('hello', 1)"
    end
  end

  test "inherits env vars from elixir" do
    # We set PYTHONX_TEST_ENV_VAR in test_helper.exs, before initializing
    # Pythonx. That env var should be available to Python.

    assert {result, %{}} =
             Pythonx.eval(
               """
               import os
               os.environ["PYTHONX_TEST_ENV_VAR"]
               """,
               %{}
             )

    assert repr(result) == "'value'"
  end

  defp repr(object) do
    assert %Pythonx.Object{} = object

    object
    |> Pythonx.NIF.object_repr()
    |> Pythonx.NIF.unicode_to_string()
  end

  defp eval_result(code) do
    assert {result, %{}} = Pythonx.eval(code, %{})
    result
  end
end
