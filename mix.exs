if System.otp_release() < "25" do
  Mix.raise("Pythonx requires Erlang/OTP 25+")
end

defmodule Pythonx.MixProject do
  use Mix.Project

  @version "0.4.6"
  @description "Python interpreter embedded in Elixir"
  @github_url "https://github.com/livebook-dev/pythonx"

  def project do
    [
      app: :pythonx,
      version: @version,
      elixir: "~> 1.15",
      name: "Pythonx",
      description: @description,
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      compilers: [:elixir_make] ++ Mix.compilers(),
      docs: docs(),
      package: package(),
      make_env: fn -> %{"FINE_INCLUDE_DIR" => Fine.include_dir()} end,
      # Precompilation
      make_precompiler: {:nif, CCPrecompiler},
      make_precompiler_url: "#{@github_url}/releases/download/v#{@version}/@{artefact_filename}",
      make_precompiler_filename: "libpythonx",
      make_precompiler_nif_versions: [versions: ["2.16"]]
    ]
  end

  def application do
    [
      extra_applications: [:logger, :inets, :ssl, :public_key],
      mod: {Pythonx.Application, []}
    ]
  end

  defp deps do
    [
      {:fine, "~> 0.1.2", runtime: false},
      {:elixir_make, "~> 0.9", runtime: false},
      {:cc_precompiler, "~> 0.1", runtime: false},
      {:ex_doc, "~> 0.36", only: :dev, runtime: false}
    ]
  end

  defp docs() do
    [
      main: "Pythonx",
      source_url: @github_url,
      source_ref: "v#{@version}"
    ]
  end

  defp package do
    [
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => @github_url},
      files:
        ~w(c_src lib mix.exs README.md LICENSE CHANGELOG.md Makefile Makefile.win checksum.exs)
    ]
  end
end
