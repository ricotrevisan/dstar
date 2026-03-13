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
      description: "A simplified Datastar implementation for Elixir using pure Plugs",
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
      links: %{"GitHub" => @source_url}
    ]
  end

  defp docs do
    [
      main: "Dstar",
      source_url: @source_url
    ]
  end
end
