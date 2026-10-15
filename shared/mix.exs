# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SukhiShared.MixProject do
  use Mix.Project

  @moduledoc false

  # Code that the gateway and the delivery node must decide *identically*.
  # Each used to carry its own copy, and the copies drifted (UrlGuard's
  # 192.0.0.0/16 rule, fixed in one on 2026-09-22 and in the other weeks
  # later). A path dependency of elixir/, delivery/ and combined/; no deps of
  # its own, so it adds nothing to any release.
  def project do
    [
      app: :sukhi_shared,
      version: "0.1.0",
      elixir: "~> 1.20",
      deps: []
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end
end
