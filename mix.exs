defmodule Zaik.MixProject do
  use Mix.Project

  def project do
    [
      app: :zaik,
      version: "0.1.0",
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: "A personal AI agent runtime inspired by OpenClaw",
      package: package(),
      source_url: "https://github.com/yourusername/zaik"
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto, :inets, :ssl],
      mod: {Zaik.Application, []}
    ]
  end

  defp deps do
    [
      {:jason, "~> 1.4"},
      {:exqlite, "~> 0.39.0"}
    ]
  end

  defp package do
    [
      files: ["lib", "mix.exs", "README.md", "LICENSE"],
      maintainers: ["Your Name"],
      licenses: ["MIT"],
      links: %{"GitHub" => "https://github.com/yourusername/zaik"}
    ]
  end
end
