defmodule SukhiHosi.MixProject do
  use Mix.Project

  def project do
    [app: :sukhi_hosi, version: "0.0.1", elixir: "~> 1.15", deps: deps()]
  end

  def application, do: [extra_applications: [:logger]]

  # Not wired into elixir/ yet: a standalone project. HOSIGRAPH_EX points at a checkout of
  # sukhi-social/hosigraph's hosigraph-ex (the default is a sibling of this repo).
  # hosigraph-ex builds its NIF against libhosi: see its README ("Getting libhosi").
  defp deps,
    do: [
      {:hosi, path: System.get_env("HOSIGRAPH_EX") || "../../hosigraph/hosigraph-ex"},
      {:postgrex, "~> 0.22.4"},
      {:jason, "~> 1.4"}
    ]
end
