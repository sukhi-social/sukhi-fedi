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

  # DeployEx decides "is a deploy needed?" by comparing the version string
  # in current.json against the one it is already running — the `hash`
  # field next to it is carried along but never compared. VERSION only
  # moves on a release, so every build in between would be a silent
  # no-op. bin/release-on-box.sh stamps the commit into SemVer build
  # metadata (`0.4.14+8f3c1d2`) so each commit is its own version; unset
  # (compose, `make dev`, the ghcr images) it stays the plain VERSION.
  @version (System.get_env("SUKHI_RELEASE_VERSION") ||
              Path.expand("../VERSION", __DIR__) |> File.read!() |> String.trim())

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

  @runtime_configs [
    "elixir/config/runtime.exs",
    "delivery/config/runtime.exs",
    "api/config/runtime.exs"
  ]

  @doc false
  def copy_runtime_configs(release) do
    # Registering them in `:overlays` is the part that matters: the :tar
    # step packs a tracked list (bin / erts / lib / releases / overlays),
    # not whatever happens to be sitting in the release directory. Copying
    # without registering leaves files that exist on disk and vanish in
    # the tarball — which fails only later, at boot, somewhere else.
    copied =
      for rel <- @runtime_configs do
        target = Path.join("runtime-configs", rel)
        dest = Path.join(release.path, target)
        File.mkdir_p!(Path.dirname(dest))
        File.cp!(Path.expand("../#{rel}", __DIR__), dest)
        target
      end

    update_in(release.overlays, &(&1 ++ copied))
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
        # :tar is what turns the assembled release into the single
        # artifact DeployEx picks up from the dist dir. The Docker image
        # build ignores it and keeps copying out of _build/prod/rel.
        #
        # The step in between is what makes that tarball self-sufficient:
        # config/runtime.exs here re-reads the three projects' own runtime
        # configs, and outside a repo checkout they have to travel with
        # the release. The Docker image used to be the only thing that
        # supplied them (it copies them in and sets RUNTIME_CONFIG_DIR),
        # so a release unpacked anywhere else died at boot looking for
        # elixir/config/runtime.exs.
        steps: [:assemble, &__MODULE__.copy_runtime_configs/1, :tar],
        applications: [
          sukhi_fedi: :permanent,
          sukhi_delivery: :permanent,
          sukhi_api: :permanent
        ]
      ]
    ]
  end
end
