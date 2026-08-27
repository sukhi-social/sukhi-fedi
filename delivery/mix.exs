# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SukhiDelivery.MixProject do
  use Mix.Project

  def project do
    [
      app: :sukhi_delivery,
      version: "0.1.0",
      elixir: "~> 1.20",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {SukhiDelivery.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # Database (reads outbox, writes delivery_receipts)
      {:ecto_sql, "~> 3.11"},
      {:postgrex, "~> 0.18"},

      # Job queue
      {:oban, "~> 2.18"},

      # NATS client (Micro request/reply + core pub/sub)
      {:gnat, "~> 1.8"},

      # HTTP client for outbound inbox POSTs
      {:req, "~> 0.5"},

      # Web Push: RFC 8291 payload encryption + the RFC 8292 VAPID JWT.
      # Picked for narrowness, not popularity (docs/WEBPUSH.md §5): its
      # only dependency is Finch, which this node already supervises, so
      # nothing new lands on the box at all.
      #
      # The obvious alternative, `web_push_elixir`, was tried first and
      # put back: it emits `aesgcm`, the superseded draft encoding, where
      # the standard (RFC 8188/8291, and what §4 asks for) is `aes128gcm`.
      # Hand-rolling on `:crypto` was the other option — every primitive
      # is in OTP — but this crypto fails *silently* when it is subtly
      # wrong: the push service answers 201 and the browser shows nothing.
      # `test/web_push_round_trip_test.exs` decrypts what we encrypt, so
      # that silence can't hide here.
      {:web_push, "~> 0.1"},

      # Plug is required transitively by PromEx even when the metrics
      # server is disabled — it imports Plug.Conn at compile time.
      {:plug, "~> 1.16"},

      # Observability — mirrors the gateway's stack.
      {:telemetry, "~> 1.2"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.1"},
      {:prom_ex, "~> 1.9"},

      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:bypass, "~> 2.1", only: :test},
      {:mox, "~> 1.0", only: :test}
    ]
  end
end
