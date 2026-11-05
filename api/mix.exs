# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SukhiApi.MixProject do
  use Mix.Project

  # Single source of truth at repo root, shared with :sukhi_fedi.
  @external_resource Path.expand("../VERSION", __DIR__)
  @version Path.expand("../VERSION", __DIR__) |> File.read!() |> String.trim()

  def project do
    [
      app: :sukhi_api,
      version: @version,
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      # `:crypto` を明示的に並べておかないと release に同梱されず、
      # SukhiApi.TokenRateLimit や OAuth view が呼ぶ `:crypto.hash/2`
      # が UndefinedFunctionError で落ちる(api は外部 deps を持たないので
      # transitive に crypto が来ないため)。
      extra_applications: [:logger, :crypto],
      mod: {SukhiApi.Application, []}
    ]
  end

  defp deps do
    [{:sukhi_shared, path: "../shared"}]
  end
end
