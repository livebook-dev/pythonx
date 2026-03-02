python_minor = System.get_env("PYTHONX_TEST_PYTHON_MINOR", "13") |> String.to_integer()

Pythonx.uv_init("""
[project]
name = "project"
version = "0.0.0"
requires-python = "==3.#{python_minor}.*"
dependencies = [
  "numpy==2.1.2",
  "cloudpickle==3.1.2"
]
""")

try_starting_epmd? = fn ->
  case :os.type() do
    {:unix, _} ->
      {"", 0} == System.cmd("epmd", ["-daemon"])

    _ ->
      true
  end
end

exclude =
  cond do
    :distributed in Keyword.get(ExUnit.configuration(), :exclude, []) ->
      []

    try_starting_epmd?.() and match?({:ok, _}, Node.start(:"primary@127.0.0.1", :longnames)) ->
      env =
        for {key, value} <- Pythonx.install_env() do
          {String.to_charlist(key), String.to_charlist(value)}
        end

      {:ok, _pid, peer1} = :peer.start(%{name: :"peer1@127.0.0.1", env: env})
      {:ok, _pid, peer2} = :peer.start(%{name: :"peer2@127.0.0.1", env: env, args: ~w(-hidden)c})

      for node <- [peer1, peer2] do
        true = :erpc.call(node, :code, :set_path, [:code.get_path()])
        {:ok, _} = :erpc.call(node, :application, :ensure_all_started, [:pythonx])
      end

      []

    true ->
      [:distributed]
  end

ExUnit.start(exclude: exclude)
