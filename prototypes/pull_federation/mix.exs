# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule PullFederation.MixProject do
  use Mix.Project

  def project do
    [
      app: :pull_federation,
      version: "0.1.0",
      elixir: "~> 1.20",
      deps: [],
      elixirc_options: [warnings_as_errors: true]
    ]
  end

  def application, do: [extra_applications: [:logger]]
end
