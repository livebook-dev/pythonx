defmodule Pythonx.AST do
  @moduledoc false

  @scan_globals_py "lib/pythonx/ast/scan_globals.py"
  @external_resource @scan_globals_py
  @scan_globals_code File.read!(@scan_globals_py)

  @doc """
  Analyzes globals in the given Python code.

  Returns a map with two entries:

    * `:referenced` - names of referenced globals that are not defined
      prior in the code

    * `:defined` - names of new globals defined in the code

  """
  @spec scan_globals(String.t()) :: %{referenced: names, defined: names}
        when names: MapSet.t(String.t())
  def scan_globals(code) when is_binary(code) do
    {result, %{}} = Pythonx.eval(@scan_globals_code, %{"code" => code})
    {referenced, defined} = Pythonx.decode(result)
    %{referenced: referenced, defined: defined}
  end
end
