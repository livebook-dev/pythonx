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

  # If configured, we fetch Python and dependencies at compile time
  # and we automatically initialize the interpreter on boot.
  if pyproject_toml = Application.compile_env(:pythonx, :uv_init)[:pyproject_toml] do
    Pythonx.Uv.fetch(pyproject_toml, true)
    defp maybe_uv_init(), do: Pythonx.Uv.init(unquote(pyproject_toml), true)
  else
    defp maybe_uv_init(), do: :noop
  end
end
