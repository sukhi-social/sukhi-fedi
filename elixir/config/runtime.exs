# SPDX-License-Identifier: AGPL-3.0-or-later
import Config

# Public-facing domain used in nodeinfo/webfinger/ActivityPub URLs.
# In prod, fetch_env! crashes the release on a missing DOMAIN rather than
# silently minting localhost:4000 URIs into outbound IDs and keyIds.
if config_env() == :prod do
  config :sukhi_fedi, :domain, System.fetch_env!("DOMAIN")
else
  config :sukhi_fedi, :domain, System.get_env("DOMAIN", "localhost:4000")
end

# Bearer for the JSON metrics endpoint (/api/metrics). Unset → the route
# 404s (feature off); set it to expose the host-resource history/snapshot
# to offline analysis. Generate with `openssl rand -hex 32`.
config :sukhi_fedi, :metrics_token, System.get_env("METRICS_TOKEN")

# Whether signup needs an invite code.
#   INVITE_REQUIRED=true  (default) — invite-only, as sukhi grew up.
#   INVITE_REQUIRED=false           — anyone may register.
# The mailbox is still proven either way: an address is how somebody
# finds their way back after losing the account. Codes keep working
# when the door is open — an invited newcomer still follows whoever
# invited them.
config :sukhi_fedi,
       :invite_required,
       System.get_env("INVITE_REQUIRED", "true") != "false"

# WebTransport のエッジ（karutte, webtransport.f3liz.casa）。`WT_TICKET_KEY` は入場チケットを
# 署名する Ed25519 の秘密鍵（生 32 バイト seed の base64）。公開鍵は karutte の `:ticket_pubkey`
# に置く。未設定なら `/api/wt` は 503（発券しない）。
config :sukhi_fedi, :wt_ticket_key, System.get_env("WT_TICKET_KEY")
config :sukhi_fedi, :wt_endpoint, System.get_env("WT_ENDPOINT", "https://webtransport.f3liz.casa/wt")

# Server-rendered HTML preview for logged-out visitors and crawlers
# (SukhiFedi.Web.PublicPreviewController). The SPA is JS-only, so without
# this a shared `/@alice` or note link unfurls as an empty shell.
#   PUBLIC_PREVIEW=off  (default) — no preview; AP JSON / SPA shell as before.
#   PUBLIC_PREVIEW=meta           — only OG/Twitter-card + JSON-LD head meta.
#   PUBLIC_PREVIEW=full           — meta + a readable static body.
# Only public-visibility content is ever rendered. Off by default so a
# quiet instance stays a shell to strangers until an operator opts in.
public_preview =
  case System.get_env("PUBLIC_PREVIEW", "off") do
    "meta" -> :meta
    "full" -> :full
    _ -> :off
  end

config :sukhi_fedi, :public_preview, public_preview

# Whether the preview pages invite indexing. Defaults to the quiet
# `noindex, nofollow`; a public instance sets PUBLIC_PREVIEW_ROBOTS to
# `index, follow` (or any meta-robots string) to be crawled.
config :sukhi_fedi,
       :public_preview_robots,
       System.get_env("PUBLIC_PREVIEW_ROBOTS", "noindex, nofollow")

# Addon selection.
#   ENABLED_ADDONS: comma list of ids, or "all" (default).
#   ADDON_PRESETS:  comma list of preset ids (see SukhiFedi.Addon.Presets).
#                   Expanded and unioned with ENABLED_ADDONS.
#   DISABLE_ADDONS: comma list of ids to always exclude (deny-list wins).
presets =
  System.get_env("ADDON_PRESETS", "")
  |> String.split(",", trim: true)
  |> Enum.map(&String.to_atom/1)

# When ADDON_PRESETS is set, it becomes the effective allowlist (union
# with any explicit ENABLED_ADDONS list). ENABLED_ADDONS=all only wins
# if it was *explicitly* set; the implicit default ("all" when unset)
# yields to the preset so operators who pick a preset aren't surprised
# by every addon silently turning on.
enabled_addons =
  case {System.get_env("ENABLED_ADDONS"), presets} do
    {nil, []} ->
      :all

    {nil, ids} ->
      SukhiFedi.Addon.Presets.expand(ids)

    {"all", _} ->
      :all

    {"", []} ->
      :all

    {"", ids} ->
      SukhiFedi.Addon.Presets.expand(ids)

    {csv, ids} ->
      explicit = csv |> String.split(",", trim: true) |> Enum.map(&String.to_atom/1)
      Enum.uniq(SukhiFedi.Addon.Presets.expand(ids) ++ explicit)
  end

disabled_addons =
  System.get_env("DISABLE_ADDONS", "")
  |> String.split(",", trim: true)
  |> Enum.map(&String.to_atom/1)

config :sukhi_fedi, :enabled_addons, enabled_addons
config :sukhi_fedi, :disabled_addons, disabled_addons

# ── Object storage (S3-compatible, rustfs in prod) ───────────────────────
# media.ex の uploads はこの bucket に PutObject される。endpoint /
# 認証情報が無い env(test / 素の dev)では設定しない ─ persist_bytes が
# {:error, :not_configured} を返す。
endpoint = System.get_env("S3_ENDPOINT")

if endpoint do
  uri = URI.parse(endpoint)
  scheme = "#{uri.scheme}://"
  port = uri.port || if(uri.scheme == "https", do: 443, else: 80)

  config :ex_aws, :s3,
    scheme: scheme,
    host: uri.host,
    port: port,
    region: System.get_env("S3_REGION", "us-east-1")

  config :ex_aws,
    access_key_id: System.fetch_env!("S3_ACCESS_KEY_ID"),
    secret_access_key: System.fetch_env!("S3_SECRET_ACCESS_KEY"),
    json_codec: Jason

  config :sukhi_fedi, :s3,
    bucket: System.get_env("S3_BUCKET", "media"),
    inbound_bucket: System.get_env("S3_INBOUND_BUCKET", "inbound"),
    outbound_bucket: System.get_env("S3_OUTBOUND_BUCKET", "outbound"),
    enabled: true
else
  config :sukhi_fedi, :s3, enabled: false
end

# ── Transactional mail (OCI Email Delivery or any SMTP relay) ────────────
# Verification / login codes go out through here. Without SMTP_HOST the
# Mailer uses the log transport: the mail lands in the logs instead of a
# mailbox — fine for dev, and an explicit "not wired up yet" in prod.
# For OCI Email Delivery: host smtp.email.<region>.oci.oraclecloud.com,
# port 587 (STARTTLS), the SMTP credentials of a user in the tenancy,
# and MAIL_FROM must be a registered approved sender.
smtp_host = System.get_env("SMTP_HOST")

cond do
  # test.exs pins the capture transport; don't let runtime override it.
  config_env() == :test ->
    :ok

  smtp_host ->
    config :sukhi_fedi, :mailer,
      transport: SukhiFedi.Mailer.SMTP,
      host: smtp_host,
      port: String.to_integer(System.get_env("SMTP_PORT", "587")),
      username: System.fetch_env!("SMTP_USERNAME"),
      password: System.fetch_env!("SMTP_PASSWORD"),
      from: System.fetch_env!("MAIL_FROM")

  true ->
    config :sukhi_fedi, :mailer,
      transport: SukhiFedi.Mailer.Log,
      from: System.get_env("MAIL_FROM", "no-reply@localhost")
end

# ── Web Push (VAPID / RFC 8292) ──────────────────────────────────────────
# Off unless a keypair is configured — the same shape as SMTP being the
# log transport until SMTP_HOST is set. Generate the pair once, out of
# band, and keep it: a keypair that changes invalidates every live
# subscription, because clients encrypted against the old public key.
#
#   VAPID_PUBLIC_KEY   P-256 public key, base64url. Not secret — the
#                      client needs it, and it goes out in the instance doc.
#   VAPID_PRIVATE_KEY  The signing key. Secret, handled like SMTP_PASSWORD
#                      / SECRET_KEY_BASE. Never logged, never sent out.
#   VAPID_SUBJECT      mailto: or https: contact a push service can reach
#                      about abuse (RFC 8292 §2.1).
vapid_public = System.get_env("VAPID_PUBLIC_KEY")

if vapid_public not in [nil, ""] do
  config :sukhi_fedi, :web_push,
    public_key: vapid_public,
    private_key: System.fetch_env!("VAPID_PRIVATE_KEY"),
    subject:
      System.get_env(
        "VAPID_SUBJECT",
        "mailto:admin@" <> System.get_env("DOMAIN", "localhost")
      )
end

if config_env() == :prod do
  config :sukhi_fedi, SukhiFedi.Repo,
    database: System.get_env("DB_NAME", "sukhi_fedi"),
    username: System.fetch_env!("DB_USER"),
    password: System.fetch_env!("DB_PASS"),
    hostname: System.get_env("DB_HOST", "localhost"),
    pool_size: String.to_integer(System.get_env("DB_POOL_SIZE", "10"))

  config :sukhi_fedi, :nats,
    host: System.get_env("NATS_HOST", "127.0.0.1"),
    port: String.to_integer(System.get_env("NATS_PORT", "4222"))

  # Cookie-signing key for the admin web UI session. Must be stable
  # across deploys — rotating invalidates every logged-in admin
  # session. Generate with `openssl rand -hex 64`.
  config :sukhi_fedi, :secret_key_base, System.fetch_env!("SECRET_KEY_BASE")

  # Distributed-Erlang plugin nodes reachable via `:rpc`.
  # Comma-separated list of `<name>@<host>` atoms. Nodes not reachable at
  # request time are skipped; if none are reachable, `/api/v1/*` returns
  # 503. Example: `PLUGIN_NODES=api@api,api_admin@api-admin`.
  config :sukhi_fedi, :plugin_nodes,
    System.get_env("PLUGIN_NODES", "")
    |> String.split(",", trim: true)
    |> Enum.map(&String.to_atom/1)

  # Oban monitor queue concurrency override. NodeInfo polling fans out
  # one job per monitored instance; on a 1 GB box 5 parallel Finch
  # requests + JSON decode buffers is more than we want resident.
  # Shallow-merges with the compile-time Oban config — `:repo` and
  # `:plugins` (Cron) are inherited unchanged.
  config :sukhi_fedi, Oban,
    queues: [monitor: String.to_integer(System.get_env("OBAN_MONITOR_CONCURRENCY", "5"))]
end
