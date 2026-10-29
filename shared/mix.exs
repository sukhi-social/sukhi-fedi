# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SukhiShared.MixProject do
  use Mix.Project

  @moduledoc false

  # Code that the gateway and the delivery node must decide *identically*.
  # Each used to carry its own copy, and the copies drifted (UrlGuard's
  # 192.0.0.0/16 rule, fixed in one on 2026-09-22 and in the other weeks
  # later). A path dependency of elixir/, delivery/ and combined/. Its one
  # dependency, Ecto, is already in all three, so it adds nothing to any
  # release: the few tables it touches are written as Ecto queries (not raw
  # SQL) so they run on whatever store the caller's repo is.
  def project do
    [
      app: :sukhi_shared,
      version: "0.1.0",
      elixir: "~> 1.20",
      deps: [{:ecto, ">= 3.0.0"}]
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end
end
