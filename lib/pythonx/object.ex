defmodule Pythonx.Object do
  @moduledoc """
  A struct holding a Python object.

  This is an opaque struct used to pass Python objects around in
  Elixir code.
  """

  defstruct [:resource, :remote_info]

  @type t :: %__MODULE__{}
end

defimpl Inspect, for: Pythonx.Object do
  import Inspect.Algebra

  alias Pythonx.Object

  def inspect(%Object{} = object, _opts) do
    object_node = node(object.resource)

    remote =
      if object_node != node() do
        concat([line(), "[", "node: ", Atom.to_string(object_node), "]"])
      else
        empty()
      end

    repr_string = :erpc.call(object_node, __MODULE__, :__repr_string__, [object])

    repr_lines = String.split(repr_string, "\n")
    inner = Enum.map_intersperse(repr_lines, line(), &string/1)

    force_unfit(
      concat([
        "#Pythonx.Object<",
        nest(concat([remote, line() | inner]), 2),
        line(),
        ">"
      ])
    )
  end

  def __repr_string__(%Object{} = object) do
    object
    |> Pythonx.NIF.object_repr()
    |> Pythonx.NIF.unicode_to_string()
  end
end
