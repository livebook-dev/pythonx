defmodule Pythonx.Error do
  @moduledoc """
  An exception raised when Python raises an exception.
  """

  defexception [:lines]

  @type t :: %__MODULE__{lines: [String.t()]}

  @impl true
  def message(error) do
    lines =
      Enum.map(error.lines, fn line ->
        ["        ", line]
      end)

    IO.iodata_to_binary(["Python exception raised\n\n", lines])
  end
end
