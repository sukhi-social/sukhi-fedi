# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SukhiFedi.MixProject do
  use Mix.Project

  # The single source of truth lives at the repo root in `VERSION`.
  # Both `:sukhi_fedi` and `:sukhi_api` read from it, the release CI
  # bumps it once and tags off the same string, so /nodeinfo/2.1 and
  # /api/v1/instance can never drift.
  @external_resource Path.expand("../VERSION", __DIR__)
  @version Path.expand("../VERSION", __DIR__) |> File.read!() |> String.trim()

  def project do
    [
      app: :sukhi_fedi,
      version: @version,
      elixir: "~> 1.20",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :os_mon],
      mod: {SukhiFedi.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # HTTP server
      {:bandit, "~> 1.5"},
      {:plug, "~> 1.16"},

      # JSON — our own code uses the stdlib `JSON` module (Elixir 1.18+);
      # Jason is kept only because ex_aws's `json_codec` and Plug.Parsers'
      # `json_decoder` reference it directly (see config + router.ex).
      {:jason, "~> 1.4"},

      # JSON-LD → RDF + canonicalization (URDNA2015/RDFC-1.0), for the
      # RsaSignature2017 LD signatures in SukhiFedi.Fedi (the native
      # replacement of the Bun fedify service). json_ld's default HTTP
      # loader is never used: contexts are vendored in priv/fedify/contexts
      # and served by Fedi.Canon.ContextLoader.
      {:rdf, "~> 3.0"},
      {:json_ld, "~> 1.0"},

      # Database
      {:ecto_sql, "~> 3.11"},
      {:postgrex, "~> 0.18"},

      # Job queue
      {:oban, "~> 2.18"},

      # NATS client
      {:gnat, "~> 1.8"},

      # HTTP client
      {:req, "~> 0.5"},

      # S3-compatible object store client (talks to the rustfs
      # accessory in prod; can point at minio / AWS S3 / etc. via
      # S3_ENDPOINT). ex_aws needs its own HTTP + XML deps because
      # it predates Req.
      {:ex_aws, "~> 2.5"},
      {:ex_aws_s3, "~> 2.5"},
      {:hackney, "~> 1.20"},
      {:sweet_xml, "~> 0.7"},

      # zstd (NIF) — compresses inbound AP originals before they land in
      # the `inbound` bucket (Q10 archive layer). Mature, stable wire
      # format, so an archived original stays decodable long-term.
      {:ezstd, "~> 1.0"},

      # libvips (NIF) — remote media proxy の WebP / AVIF 変換レイヤー
      # (Web.MediaTranscode)。precompiled の NIF + libvips が hex /
      # GitHub releases から落ちてくるので、alpine(musl) の build /
      # runtime に追加パッケージは要らない(libstdc++ は既にある)。
      {:vix, "~> 0.40"},

      # Lightweight observability: telemetry + PromEx (Prometheus).
      # Distributed tracing is intentionally omitted — use structured
      # Logger messages and Prometheus histograms instead.
      {:telemetry, "~> 1.2"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.1"},
      {:prom_ex, "~> 1.9"},

      # Rate limiting (ETS-backed, node-local).
      {:hammer, "~> 6.1"},

      # Password hashing for local accounts.
      {:argon2_elixir, "~> 4.0"},

      # SMTP client for transactional mail (email verification / login
      # codes). Prod points it at OCI Email Delivery via SMTP_* env vars;
      # without them the Mailer falls back to a log transport.
      {:gen_smtp, "~> 1.2"},

      # WebAuthn (passkey) attestation/assertion verification. The
      # credential and challenge storage stays in our own tables; Wax
      # only does the spec-heavy byte checking — same "lean on a focused
      # lib for exactly its slice" call as fedify for HTTP signatures.
      {:wax_, "~> 0.7"},

      # HTML sanitisation (allow-list) for note content and account bios —
      # both local input and federated remote HTML — before they reach the
      # SPA's `{@html}` sinks. Mastodon's model: sanitise on the way in.
      {:html_sanitize_ex, "~> 1.4"},

      # Markdown → HTML for the static legal pages (terms/privacy). Pure
      # Elixir, used at compile time only; the rendered HTML is baked into
      # the release, so serving it at runtime can't fail.
      {:earmark, "~> 1.4"},

      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:bypass, "~> 2.1", only: :test},
      {:mox, "~> 1.0", only: :test}
    ]
  end
end
