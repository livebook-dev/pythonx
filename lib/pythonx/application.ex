defmodule Pythonx.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    enable_sigchld()

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
  uv_init_env = Application.compile_env(:pythonx, :uv_init)
  pyproject_toml = uv_init_env[:pyproject_toml]
  uv_version = uv_init_env[:uv_version] || Pythonx.Uv.default_uv_version()
  opts = [uv_version: uv_version]

  if pyproject_toml do
    Pythonx.Uv.fetch(pyproject_toml, true, opts)
    defp maybe_uv_init(), do: Pythonx.Uv.init(unquote(pyproject_toml), true, unquote(opts))
  else
    defp maybe_uv_init() do
      case Pythonx.init_state_from_env() do
        nil ->
          :noop

        init_state_env_value ->
          init_state_env_value
          |> Base.decode64!()
          |> :erlang.binary_to_term()
          |> Pythonx.init()
      end
    end
  end

  defp enable_sigchld() do
    # Some APIs in Python, such as subprocess.run, wait for a child
    # OS process to finish. On Unix, this relies on `waitpid` C API,
    # which does not work properly if SIGCHLD is ignored, resulting
    # in infinite waiting. ERTS ignores the signal by default, so we
    # explicitly restore the default handler.
    case :os.type() do
      {:win32, _osname} -> :ok
      {:unix, _osname} -> :os.set_signal(:sigchld, :default)
    end
  end
end
