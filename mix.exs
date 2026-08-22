defmodule Zaik.MixProject do
  use Mix.Project

  def project do
    [
      app: :zaik,
      version: "0.1.0",
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: "A local-first Elixir/OTP personal agent harness",
      package: package(),
      source_url: "https://github.com/debussyman/zaik"
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
      maintainers: ["Ryan Cooke"],
      licenses: ["MIT"],
      links: %{"GitHub" => "https://github.com/debussyman/zaik"}
    ]
  end
end
