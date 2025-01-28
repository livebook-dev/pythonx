defmodule Pythonx.ASTTest do
  use ExUnit.Case, async: true

  describe "scan_globals/1" do
    test "assign" do
      assert Pythonx.AST.scan_globals("""
             x = 1
             """) == %{referenced: MapSet.new([]), defined: MapSet.new(["x"])}

      assert Pythonx.AST.scan_globals("""
             x, y = 1, 2
             """) == %{referenced: MapSet.new([]), defined: MapSet.new(["x", "y"])}
    end

    test "augmented assign" do
      assert Pythonx.AST.scan_globals("""
             x += 1
             """) == %{referenced: MapSet.new(["x"]), defined: MapSet.new(["x"])}
    end

    test "annotated assign" do
      assert Pythonx.AST.scan_globals("""
             x: int = 1
             """) == %{referenced: MapSet.new([]), defined: MapSet.new(["x"])}
    end

    test "import" do
      assert Pythonx.AST.scan_globals("""
             import ast
             import numpy.random
             import math as m
             """) == %{
               referenced: MapSet.new([]),
               defined: MapSet.new(["ast", "numpy", "m"])
             }
    end

    test "import from" do
      assert Pythonx.AST.scan_globals("""
             from math import pi
             from numpy.linalg import dot, inv
             """) == %{
               referenced: MapSet.new([]),
               defined: MapSet.new(["pi", "dot", "inv"])
             }
    end

    test "function definition" do
      assert Pythonx.AST.scan_globals("""
             def fun():
               import ast
               x = 1
               return x + 1
             """) == %{referenced: MapSet.new([]), defined: MapSet.new(["fun"])}
    end

    test "function definition with global as argument default" do
      assert Pythonx.AST.scan_globals("""
             def fun(x=x):
               return x
             """) == %{referenced: MapSet.new(["x"]), defined: MapSet.new(["fun"])}
    end

    test "async function definition" do
      assert Pythonx.AST.scan_globals("""
             async def fun():
               import ast
               x = 1
               return x + 1
             """) == %{referenced: MapSet.new([]), defined: MapSet.new(["fun"])}
    end

    test "class definition" do
      assert Pythonx.AST.scan_globals("""
             class Cl:
               def fun():
                 import ast
                 x = 1
                 return x + 1
             """) == %{referenced: MapSet.new([]), defined: MapSet.new(["Cl"])}
    end

    test "comprehension" do
      assert Pythonx.AST.scan_globals("""
             [num * num for num in nums]
             """) == %{referenced: MapSet.new(["nums"]), defined: MapSet.new([])}

      assert Pythonx.AST.scan_globals("""
             {num * num for num in nums}
             """) == %{referenced: MapSet.new(["nums"]), defined: MapSet.new([])}

      assert Pythonx.AST.scan_globals("""
             (num * num for num in nums)
             """) == %{referenced: MapSet.new(["nums"]), defined: MapSet.new([])}

      assert Pythonx.AST.scan_globals("""
             {num: num for num in nums}
             """) == %{referenced: MapSet.new(["nums"]), defined: MapSet.new([])}

      assert Pythonx.AST.scan_globals("""
             [x * x for x in x]
             """) == %{referenced: MapSet.new(["x"]), defined: MapSet.new([])}
    end

    test "comprehension with walrus operator" do
      # The := assignment leaks to the outer scope

      assert Pythonx.AST.scan_globals("""
             [square := num * num for num in nums]
             """) == %{referenced: MapSet.new(["nums"]), defined: MapSet.new(["square"])}

      assert Pythonx.AST.scan_globals("""
             {square := num * num for num in nums}
             """) == %{referenced: MapSet.new(["nums"]), defined: MapSet.new(["square"])}

      assert Pythonx.AST.scan_globals("""
             {num: (square := num * num) for num in nums}
             """) == %{referenced: MapSet.new(["nums"]), defined: MapSet.new(["square"])}
    end

    test "lambda" do
      assert Pythonx.AST.scan_globals("""
             x = lambda a, b: a + b
             """) == %{referenced: MapSet.new([]), defined: MapSet.new(["x"])}
    end

    test "for" do
      assert Pythonx.AST.scan_globals("""
             for num in nums:
               num
             """) == %{referenced: MapSet.new(["nums"]), defined: MapSet.new(["num"])}
    end

    test "if" do
      # Python allows for defining different variables in conditional
      # branches, but that's only resolved at runtime, so we extract
      # globals from both branches.

      assert Pythonx.AST.scan_globals("""
             if True:
               x = 1
             else:
               y = 2
             """) == %{referenced: MapSet.new([]), defined: MapSet.new(["x", "y"])}
    end

    test "match" do
      # Same as with if, we extract globals from all branches.

      assert Pythonx.AST.scan_globals("""
             subject = {'x': 1}

             match subject:
               case {'x': x}:
                 a = x
               case {'y': y}:
                 b = y
               case {**rest}:
                 c = rest
             """) == %{
               referenced: MapSet.new([]),
               defined: MapSet.new(["subject", "x", "y", "a", "b", "c", "rest"])
             }

      assert Pythonx.AST.scan_globals("""
             subject = [1, 2, 3]

             match subject:
               case [1, x]:
                 a = x
               case [1, y, *rest]:
                 b = y
             """) == %{
               referenced: MapSet.new([]),
               defined: MapSet.new(["subject", "x", "y", "a", "b", "rest"])
             }

      assert Pythonx.AST.scan_globals("""
             subject = [1, 2, 3]

             match subject:
               case [x] if x > 0:
                 a = 1
               case tuple():
                 b = 1
             """) == %{
               referenced: MapSet.new([]),
               defined: MapSet.new(["subject", "x", "a", "b"])
             }

      assert Pythonx.AST.scan_globals("""
             subject = [1, 2, 3]

             match subject:
               case [x] as y:
                 a = y
             """) == %{
               referenced: MapSet.new([]),
               defined: MapSet.new(["subject", "x", "y", "a"])
             }
    end

    test "try" do
      assert Pythonx.AST.scan_globals("""
             try:
               raise RuntimeError("error")
             except RuntimeError as e:
               x = e
             """) == %{referenced: MapSet.new([]), defined: MapSet.new(["x"])}

      assert Pythonx.AST.scan_globals("""
             try:
               raise RuntimeError("error")
             except RuntimeError as e1:
               try:
                 raise RuntimeError("error")
               except RuntimeError as e2:
                 x = (e1, e2)
             """) == %{referenced: MapSet.new([]), defined: MapSet.new(["x"])}
    end

    test "global in top-level expression" do
      assert Pythonx.AST.scan_globals("""
             x + 1
             """) == %{referenced: MapSet.new(["x"]), defined: MapSet.new([])}
    end

    test "global in function" do
      assert Pythonx.AST.scan_globals("""
             def fun(y):
               return x + y
             """) == %{referenced: MapSet.new(["x"]), defined: MapSet.new(["fun"])}
    end

    test "global in class" do
      assert Pythonx.AST.scan_globals("""
             class Cl:
               def fun(y):
                 return x + y
             """) == %{referenced: MapSet.new(["x"]), defined: MapSet.new(["Cl"])}
    end

    test "global definition before use" do
      assert Pythonx.AST.scan_globals("""
             x = 1
             x + 1
             """) == %{referenced: MapSet.new([]), defined: MapSet.new(["x"])}

      assert Pythonx.AST.scan_globals("""
             x = 1
             x += 1
             """) == %{referenced: MapSet.new([]), defined: MapSet.new(["x"])}
    end

    test "global definition after use" do
      assert Pythonx.AST.scan_globals("""
             x + 1
             x = 1
             """) == %{referenced: MapSet.new(["x"]), defined: MapSet.new(["x"])}

      assert Pythonx.AST.scan_globals("""
             x = x + 1
             """) == %{referenced: MapSet.new(["x"]), defined: MapSet.new(["x"])}

      assert Pythonx.AST.scan_globals("""
             x += x + 1
             """) == %{referenced: MapSet.new(["x"]), defined: MapSet.new(["x"])}
    end

    test "ignores builtins in references" do
      assert Pythonx.AST.scan_globals("""
             print(1)
             len([])
             """) == %{referenced: MapSet.new([]), defined: MapSet.new([])}
    end
  end
end
