# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule MnesiaQueue.MixProject do
  use Mix.Project

  def project do
    [
      app: :mnesia_queue,
      version: "0.0.0",
      elixir: "~> 1.17",
      deps: [],
      elixirc_paths: ["lib"]
    ]
  end

  def application, do: [extra_applications: [:logger, :mnesia]]
end
