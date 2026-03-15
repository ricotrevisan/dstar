defmodule Dstar.MixProject do
  use Mix.Project

  @version "0.0.1"
  @source_url "https://github.com/ricotrevisan/dstar"

  def project do
    [
      app: :dstar,
      version: @version,
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: "Datastar SSE helpers for Elixir — pure functions, no framework",
      package: package(),
      docs: docs()
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:plug, "~> 1.14"},
      {:jason, "~> 1.4"},
      {:ex_doc, "~> 0.29", only: :dev, runtime: false}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      maintainers: ["Rico Trevisan"],
      files: ~w(lib .formatter.exs mix.exs README.md LICENSE)
    ]
  end

  defp docs do
    [
      main: "Dstar",
      source_url: @source_url,
      source_ref: "v#{@version}",
      extras: ["README.md"],
      groups_for_modules: [
        Core: [Dstar, Dstar.SSE, Dstar.Signals, Dstar.Elements, Dstar.Actions, Dstar.Scripts],
        Plugs: [Dstar.Plugs.Dispatch, Dstar.Plugs.RenameCsrfParam]
      ]
    ]
  end
end
