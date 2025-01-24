if System.otp_release() < "25" do
  Mix.raise("Pythonx requires Erlang/OTP 25+")
end

defmodule Pythonx.MixProject do
  use Mix.Project

  def project do
    [
      app: :pythonx,
      version: "0.3.0",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      compilers: [:elixir_make] ++ Mix.compilers(),
      docs: &docs/0
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Pythonx.Application, []}
    ]
  end

  defp deps do
    [
      {:elixir_make, "~> 0.9", runtime: false},
      {:ex_doc, "~> 0.36", only: :dev, runtime: false}
    ]
  end

  defp docs() do
    []
  end
end
