# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Combined release shell: gateway (:sukhi_fedi) + delivery
# (:sukhi_delivery) + api (:sukhi_api) in one BEAM for single-box
# deployments. No code lives here — the three apps stay separate
# projects and keep their own boundaries (ARCHITECTURE.md §2); this
# project only assembles one release out of them. The multi-VM
# deployment keeps building from elixir/, delivery/ and api/ exactly
# as before.
#
# §2's rules 1-6 hold unchanged: only the process count differs. In
# particular rule 6 (Mastodon/Misskey REST runs on the api plugin
# node, reached via `:rpc`) still holds literally — `:rpc.call/5`
# with the local node is a local call. The entrypoint points
# PLUGIN_NODES and GATEWAY_NODE at this release's own node so both
# directions resolve to self.
defmodule SukhiCombined.MixProject do
  use Mix.Project

  @external_resource Path.expand("../VERSION", __DIR__)
  @version Path.expand("../VERSION", __DIR__) |> File.read!() |> String.trim()

  def project do
    [
      app: :sukhi_combined,
      version: @version,
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      releases: releases()
    ]
  end

  def application do
    [extra_applications: []]
  end

  defp deps do
    [
      {:sukhi_fedi, path: "../elixir"},
      {:sukhi_delivery, path: "../delivery"},
      {:sukhi_api, path: "../api"}
    ]
  end

  defp releases do
    [
      combined: [
        applications: [
          sukhi_fedi: :permanent,
          sukhi_delivery: :permanent,
          sukhi_api: :permanent
        ]
      ]
    ]
  end
end
