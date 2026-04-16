defmodule Dstar.MixProject do
  use Mix.Project

  @version "0.0.8"
  @source_url "https://github.com/ricotrevisan/dstar"

  def project do
    [
      app: :dstar,
      version: @version,
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description:
        "Batteries-included Datastar toolkit for Elixir: SSE primitives, event dispatch, CSRF, and more. For any Plug or Phoenix app.",
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
      files:
        ~w(lib docs usage-rules.md usage-rules .formatter.exs mix.exs README.md CHANGELOG.md LICENSE)
    ]
  end

  defp docs do
    [
      main: "readme",
      source_url: @source_url,
      source_ref: "v#{@version}",
      extras: ["README.md", "CHANGELOG.md", "docs/migrating-from-phoenix-datastar.md"],
      groups_for_modules: [
        Core: [Dstar, Dstar.SSE, Dstar.Signals, Dstar.Elements, Dstar.Actions, Dstar.Scripts],
        Plugs: [Dstar.Plugs.Dispatch, Dstar.Plugs.RenameCsrfParam],
        Utilities: [Dstar.Utility.StreamRegistry]
      ]
    ]
  end
end
