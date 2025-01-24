defmodule Pythonx.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      Pythonx.Janitor
    ]

    opts = [strategy: :one_for_one, name: Pythonx.Supervisor]

    with {:ok, result} <- Supervisor.start_link(children, opts) do
      maybe_uv_init()

      {:ok, result}
    end
  end

  # If configured, Python and dependencies are fetched at compile time,
  # so we automatically initialize the interpreter on boot.
  if pyproject_toml = Application.compile_env(:pythonx, :uv_pyproject_toml) do
    defp maybe_uv_init(), do: Pythonx.Uv.init(unquote(pyproject_toml), true)
  else
    defp maybe_uv_init(), do: :noop
  end
end

# If configured, fetch Python and dependencies when compiling.
if pyproject_toml = Application.compile_env(:pythonx, :uv_pyproject_toml) do
  Pythonx.Uv.fetch(pyproject_toml, true)
end
