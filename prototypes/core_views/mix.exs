# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule CoreViews.MixProject do
  use Mix.Project

  # hosigraph `main` at the merge of the facts-and-views `ecto_hosi`.
  @hosigraph "266b4f2d8539942c57d84baed73aaacfa0c59820"

  def project do
    [
      app: :core_views,
      version: "0.1.0",
      elixir: "~> 1.19",
      elixirc_paths: if(Mix.env() == :test, do: ["lib", "test/support"], else: ["lib"]),
      deps: deps()
    ]
  end

  def application, do: [extra_applications: [:logger]]

  defp deps do
    [dep(:ecto_hosi, "ECTO_HOSI_PATH", "ecto_hosi"), dep(:hosi, "HOSI_PATH", "hosigraph-ex")]
  end

  # `ECTO_HOSI_PATH` and `HOSI_PATH` point at a local checkout, as in `elixir/mix.exs`.
  defp dep(name, env, sparse) do
    case System.get_env(env) do
      nil ->
        {name, github: "sukhi-social/hosigraph", sparse: sparse, ref: full_ref(), override: true}

      path ->
        {name, path: path, override: true}
    end
  end

  defp full_ref, do: System.get_env("HOSIGRAPH_REF", @hosigraph)
end
