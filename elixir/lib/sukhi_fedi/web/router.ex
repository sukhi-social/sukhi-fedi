# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Web.Router do
  use Plug.Router

  alias SukhiFedi.Web.InboxController
  alias SukhiFedi.Web.WebfingerController
  alias SukhiFedi.Web.NodeinfoController
  alias SukhiFedi.Web.ActorController
  alias SukhiFedi.Web.FeaturedController
  alias SukhiFedi.Web.CollectionController
  alias SukhiFedi.Web.NoteController
  alias SukhiFedi.Web.QuoteAuthorizationController
  alias SukhiFedi.Web.ViewerController
  alias SukhiFedi.Web.StatsController
  alias SukhiFedi.Web.MetricsController
  alias SukhiFedi.Web.StreamingController
  alias SukhiFedi.Web.StreamingSseController
  alias SukhiFedi.Web.Auth.EmailLoginController
  alias SukhiFedi.Web.Auth.LoginController
  alias SukhiFedi.Web.Auth.PasskeyLoginController
  alias SukhiFedi.Web.Auth.PasswordController
  alias SukhiFedi.Web.Auth.SecurityController
  alias SukhiFedi.Web.SelfCleanupController
  alias SukhiFedi.Web.Auth.SignupEmailController
  alias SukhiFedi.Web.MediaProxyController
  alias SukhiFedi.Web.PublicPreviewController

  plug(Plug.Logger)
  plug(SukhiFedi.Web.AccessLogPlug)
  # CORS before the rate limiter and routing: browser clients' preflight
  # OPTIONS must be answered (204) without counting against the limit or
  # falling through to a 404. Attaches Access-Control-* to every response.
  plug(SukhiFedi.Web.CorsPlug)
  # Global per-peer rate limit. Conservative ceiling; internal probes
  # like /up from k8s LBs still fit easily. Tighten per-endpoint via
  # dedicated forwarders when needed.
  plug(SukhiFedi.Web.RateLimitPlug, bucket: "global", limit: 500, scale_ms: 60_000)
  plug(:match)

  # multipart/form-data はここでは parse しない。account の avatar/header
  # と media upload は plugin node 側で raw body から自前 parse するので、
  # ここで Plug.Upload を介して temp file に書き出されると二重コピーに
  # なる。`pass:` 指定で body は未読のまま PluginPlug に届く。
  plug(Plug.Parsers,
    parsers: [:json, :urlencoded],
    pass: ["multipart/form-data"],
    json_decoder: Jason,
    body_reader: {SukhiFedi.Web.CacheBodyReader, :read_body, []}
  )

  plug(:fetch_query_params)

  plug(:dispatch)

  # ── Admin web UI ────────────────────────────────────────────────────────
  # Forward strips the `/admin` prefix; the sub-router owns its own
  # session middleware (cookie-signed via SECRET_KEY_BASE) and runs the
  # Mastodon-OAuth-bearer auth check on every request.
  forward("/admin", to: SukhiFedi.Web.Admin.Router)

  # ── User-facing login (session_token cookie minter) ────────────────────
  # The form lives in the SPA (`web/src/routes/login`); GET serves the
  # shell, POST is the JSON endpoint that validates credentials and mints
  # the session_token cookie `/oauth/authorize` consumes.

  get "/login" do
    serve_spa(conn)
  end

  # ── Legal pages (static HTML baked at compile time) ────────────────────
  # Robust on purpose: no SPA, no JS, no DB — served even if everything
  # else is down. Source: priv/legal/*.ko.md (see LegalController).

  get "/privacy" do
    SukhiFedi.Web.LegalController.privacy(conn)
  end

  get "/terms" do
    SukhiFedi.Web.LegalController.terms(conn)
  end

  post "/login" do
    LoginController.submit(conn)
  end

  # Second step of password / email-code login when the account has
  # app-2FA enabled. Takes the pending token from POST /login plus the
  # 6-digit code, then mints the session cookie.
  post "/login/totp" do
    LoginController.totp(conn)
  end

  # Email-code login (the "メール認証" door). Request mails a code to a
  # verified address; submit exchanges it for the cookie (or the TOTP
  # step, same as the password door).
  post "/login/email/request" do
    EmailLoginController.request(conn)
  end

  post "/login/email" do
    EmailLoginController.submit(conn)
  end

  # Passkey (WebAuthn discoverable credential) login.
  post "/login/passkey/options" do
    PasskeyLoginController.options(conn)
  end

  post "/login/passkey" do
    PasskeyLoginController.submit(conn)
  end

  post "/logout" do
    LoginController.logout(conn)
  end

  # Pre-signup mailbox proof: code mail + exchange for the signed
  # email_proof that POST /api/v1/accounts now requires. Accounts are
  # born with a verified address — that's what makes the password
  # optional (and legacy).
  post "/signup/email/request" do
    SignupEmailController.request(conn)
  end

  post "/signup/email/confirm" do
    SignupEmailController.confirm(conn)
  end

  # Right after the account exists, trade the proof for a first-party
  # session — email signup gets the same standing as a password login.
  post "/signup/session" do
    SignupEmailController.session(conn)
  end

  # ── Password set / change / remove (session_token cookie required) ─────
  # Form in the SPA (`web/src/routes/settings/password`), POST is JSON.
  # Same cookie auth surface as /login (not the OAuth bearer).

  get "/settings/password" do
    serve_spa(conn)
  end

  post "/settings/password" do
    PasswordController.submit(conn)
  end

  post "/settings/password/remove" do
    PasswordController.remove(conn)
  end

  # ── Login-factor management (cookie-gated; see SecurityController) ─────
  # The page is the SPA; the POSTs are JSON. GET /auth/state also takes
  # a read-scoped bearer so the SPA can decide whether to nudge for an
  # email right after signup.

  get "/auth/state" do
    SecurityController.state(conn)
  end

  get "/settings/security" do
    serve_spa(conn)
  end

  post "/settings/reauth/request" do
    SecurityController.reauth_request(conn)
  end

  post "/settings/email/request" do
    SecurityController.email_request(conn)
  end

  post "/settings/email/confirm" do
    SecurityController.email_confirm(conn)
  end

  post "/settings/totp/setup" do
    SecurityController.totp_setup(conn)
  end

  post "/settings/totp/enable" do
    SecurityController.totp_enable(conn)
  end

  post "/settings/totp/disable" do
    SecurityController.totp_disable(conn)
  end

  post "/settings/passkeys/options" do
    SecurityController.passkey_options(conn)
  end

  post "/settings/passkeys" do
    SecurityController.passkey_register(conn)
  end

  post "/settings/passkeys/:id/delete" do
    SecurityController.passkey_delete(conn)
  end

  get "/settings/sessions" do
    SecurityController.sessions(conn)
  end

  post "/settings/sessions/:id/revoke" do
    SecurityController.session_revoke(conn)
  end

  # ── Self-cleanup (archive own old posts; cookie-gated, reauth on execute) ─
  # The page is the SPA; preview is read-only (dry-run), execute is the
  # owner-re-proof–gated commit. See SelfCleanupController.

  get "/settings/cleanup" do
    serve_spa(conn)
  end

  post "/settings/cleanup/preview" do
    SelfCleanupController.preview(conn)
  end

  post "/settings/cleanup/execute" do
    SelfCleanupController.execute(conn)
  end

  # ── Static assets for the SPA + login page ─────────────────────────────
  # The SvelteKit build at `web/build` is copied (or symlinked) into
  # `priv/static`. Cloudflare Pages style deploys can ignore this and
  # serve the SPA from the CDN; this fallback keeps a self-contained
  # one-binary deploy possible.

  get "/static/*path" do
    serve_static(conn, path)
  end

  # ── ActivityPub / well-known (handled natively by Elixir) ────────────────

  get "/.well-known/webfinger" do
    WebfingerController.call(conn, [])
  end

  # A crawler / no-JS browser asking for `/users/:name` gets the HTML
  # preview when it's enabled; an ActivityPub consumer (Accept names AP
  # JSON) gets the actor JSON exactly as before. The negotiation lives in
  # PublicPreviewController.wants_html_preview?/1 (one place).
  get "/users/:name" do
    if PublicPreviewController.wants_html_preview?(conn) do
      PublicPreviewController.profile(conn)
    else
      ActorController.show(conn, [])
    end
  end

  get "/users/:name/featured" do
    FeaturedController.show(conn, [])
  end

  get "/users/:name/followers" do
    CollectionController.followers(conn, [])
  end

  get "/users/:name/following" do
    CollectionController.following(conn, [])
  end

  # FEP-bebd follow invite, dereferenced as an InviteCode object.
  get "/users/:name/invites/:code" do
    CollectionController.invite(conn, [])
  end

  # FEP-4ccd pending collections — owner-only (session cookie), 401 otherwise.
  get "/users/:name/pendingFollowers" do
    CollectionController.pending_followers(conn, [])
  end

  get "/users/:name/pendingFollowing" do
    CollectionController.pending_following(conn, [])
  end

  get "/users/:name/outbox" do
    CollectionController.outbox(conn, [])
  end

  # Same negotiation as the actor route: HTML preview for crawler / no-JS,
  # the AP Note JSON for an ActivityPub consumer.
  get "/users/:name/notes/:note_id" do
    if PublicPreviewController.wants_html_preview?(conn) do
      PublicPreviewController.note(conn)
    else
      NoteController.show(conn, [])
    end
  end

  # FEP-7458 replies collection for a note.
  get "/users/:name/notes/:note_id/replies" do
    NoteController.replies(conn, [])
  end

  # FEP-044f: a quote authorization we granted, dereferenced by the
  # quoter's followers to verify the quote was approved.
  get "/users/:name/quote-auth/:id" do
    QuoteAuthorizationController.show(conn, [])
  end

  post "/users/:name/inbox" do
    InboxController.user_inbox(conn, [])
  end

  post "/inbox" do
    InboxController.shared_inbox(conn, [])
  end

  # ── NodeInfo (Elixir-native) ─────────────────────────────────────────────

  get "/.well-known/nodeinfo" do
    NodeinfoController.discovery(conn, [])
  end

  get "/nodeinfo/2.0" do
    NodeinfoController.v2_0(conn, [])
  end

  get "/nodeinfo/2.1" do
    NodeinfoController.v2_1(conn, [])
  end

  # ── Uploaded media ───────────────────────────────────────────────────────
  # `/uploads/<key>` を S3 互換ストレージ(prod では rustfs accessory)から
  # proxy する。`SukhiFedi.Addons.Media.create_from_upload/3` が同じ key で
  # PutObject していて、URL はこのまま DB に保存される。CDN を前に置く
  # 場合は signed URL に切り替えるか、CDN 側で cache する。

  get "/uploads/*path" do
    serve_upload(conn, path)
  end

  # ── Remote media proxy ───────────────────────────────────────────────────
  # リモート投稿の添付・avatar・banner を自ドメイン経由で配る。閲覧者の
  # IP を相手サーバへ渡さないため + CF edge cache に乗せるため。api 側の
  # view (MastodonMedia / MastodonAccount) がリモート URL をこの形に
  # 書き換える。詳細は MediaProxyController の moduledoc。

  get "/proxy/media/:id" do
    MediaProxyController.media(conn, id)
  end

  get "/proxy/avatar/:id" do
    MediaProxyController.avatar(conn, id)
  end

  get "/proxy/header/:id" do
    MediaProxyController.header(conn, id)
  end

  # ── Human-facing HTML + JSON proxy for nodeinfo lookup ──────────────────
  # Gated on the :nodeinfo_monitor addon: this is the watcher UI surface
  # (dashboard at /, register/list watchers, host stats SSE). A deployment
  # running sukhi-fedi as a real SNS — not as a watcher app — sets
  # DISABLE_ADDONS=nodeinfo_monitor and these routes go 404.

  get "/" do
    cond do
      nodeinfo_monitor_enabled?() -> ViewerController.home(conn, [])
      true -> serve_spa(conn)
    end
  end

  # SPA-owned client routes. Each one is just the same SvelteKit shell
  # (`priv/static/index.html`); the bundled JS reads the URL and
  # renders the matching page. Listing them explicitly keeps `/api`,
  # `/oauth`, `/.well-known` untouched.

  get "/signup" do
    serve_spa(conn)
  end

  # 招待リンクの玄関。`:code` は SPA 側が URL から読むので、ここでは
  # shell を返すだけ(signup と同じ)。生死の確認は GET /api/v1/invite/:code。
  get "/invite/:code" do
    serve_spa(conn)
  end

  get "/timeline" do
    serve_spa(conn)
  end

  get "/app/callback" do
    serve_spa(conn)
  end

  get "/settings" do
    serve_spa(conn)
  end

  get "/search" do
    serve_spa(conn)
  end

  get "/messages" do
    serve_spa(conn)
  end

  # 個別の会話。lists と同型で、ここを足し忘れるとアプリ内クリックは
  # SvelteKit が捌くのに直リンク / リロードだけ 404 になる。`:id` は viewer の
  # conversation_participants 行 id(SPA 側が URL から読む)。
  get "/messages/:id" do
    serve_spa(conn)
  end

  # 試作中の Clips (自分宛て DM を保存先に流用)。lists / messages/:id と
  # 同じ理由で明示が要る ── 足し忘れると直リンク / リロードだけ 404 になる。
  get "/clips" do
    serve_spa(conn)
  end

  get "/compose" do
    serve_spa(conn)
  end

  get "/notifications" do
    serve_spa(conn)
  end

  get "/bookmarks" do
    serve_spa(conn)
  end

  get "/favourites" do
    serve_spa(conn)
  end

  # フォロー承認 + 招待リンク (locked アカウントの待ち合い室)。web 側だけ
  # 足してここを忘れると、直リンク / リロードだけ 404 になる(lists と同型)。
  get "/requests" do
    serve_spa(conn)
  end

  # lists の一覧 (`/lists`) と個別リスト (`/lists/:id`)。web 側だけ足して
  # ここを足し忘れると、アプリ内クリックは SvelteKit が捌くのに直リンク /
  # リロードだけ 404 になる。
  get "/lists" do
    serve_spa(conn)
  end

  get "/lists/:id" do
    serve_spa(conn)
  end

  # ハッシュタグのタイムライン。本文中の #tag リンクと `tags` 配列の URL が
  # ここを指す。`:tag` は SPA 側が URL から読む。直リンク / リロードでも
  # shell を返せるよう、lists と同じく明示で足しておく。
  get "/tags/:tag" do
    serve_spa(conn)
  end

  # 路線図(公開ページ)。数字は GET /api/map から。
  get "/map" do
    serve_spa(conn)
  end

  # PoW で守られる「通り道」。Anubis がこの path だけを challenge する。
  # 中身は SPA shell ─ JS で intent / next を読んで分岐する。
  get "/check" do
    serve_spa(conn)
  end

  # SvelteKit がビルド出力に `_app/` を使うので、こちらも static として
  # 配る(`/static/` と同じ priv/static ルート、prefix だけ別)。
  get "/_app/*path" do
    serve_static(conn, ["_app" | path])
  end

  # Self-hosted Twemoji SVGs, baked into priv/static/twemoji by the SPA
  # build. The SPA points unicode emoji + UI icons at /twemoji/svg/<cp>.svg.
  get "/twemoji/*path" do
    serve_static(conn, ["twemoji" | path])
  end

  get "/favicon.ico" do
    serve_static(conn, ["favicon.ico"])
  end

  # Site icon — handwritten 好 (くろ lives inside it). Also the
  # /api/v2/instance thumbnail.
  get "/favicon.png" do
    serve_static(conn, ["favicon.png"])
  end

  get "/apple-touch-icon.png" do
    serve_static(conn, ["apple-touch-icon.png"])
  end

  get "/icon-512.png" do
    serve_static(conn, ["icon-512.png"])
  end

  get "/manifest.webmanifest" do
    serve_static(conn, ["manifest.webmanifest"])
  end

  # natadeco の web-natadeco 側だけが使う画像(ひなたの肖像)。他の
  # favicon 等と同じ、明示の一枚もの。
  get "/hinata.png" do
    serve_static(conn, ["hinata.png"])
  end

  # scope が `/` になるよう、ルート直下から配る。中身は static/ にある
  # 手書きの一枚(依存なし)。
  get "/service-worker.js" do
    serve_static(conn, ["service-worker.js"])
  end

  # natadeco の板の直リンク / リロード。web-natadeco の SPA も同じ shell
  # (priv/static/index.html) を返すやり方で、JS が URL を読んで描く。
  #
  # 連合側(Mastodon/Misskey)がこの URL を「返信先」として解決しようと
  # すると、`Accept: application/activity+json` で来る ── その場合は
  # SPA を返さず、本当の ap_id(/users/:name/notes/:id)へ回す。他の
  # 投稿からこの URL を貼るだけで、外から返信できて、それが板の
  # コメントとして出てくるようにするための入り口。
  get "/posts/:id" do
    if wants_activity_json?(conn) do
      redirect_to_ap_object(conn, conn.path_params["id"])
    else
      serve_spa(conn)
    end
  end

  # 板は `/d/` の下に一本化 ── これで板の slug が他のどの一段路
  # (login・settings・api 等)とも衝突しなくなった。
  get "/d/:slug/new" do
    serve_spa(conn)
  end

  get "/d/:slug" do
    serve_spa(conn)
  end

  get "/api/nodeinfo" do
    if nodeinfo_monitor_enabled?(),
      do: ViewerController.nodeinfo_lookup(conn, []),
      else: send_resp(conn, 404, "")
  end

  get "/api/watchers" do
    if nodeinfo_monitor_enabled?(),
      do: ViewerController.list_watchers(conn, []),
      else: send_resp(conn, 404, "")
  end

  post "/api/watchers" do
    if nodeinfo_monitor_enabled?(),
      do: ViewerController.register_watcher(conn, []),
      else: send_resp(conn, 404, "")
  end

  # SSE stream feeding the host-stats card on `/`. One JSON tick per second.
  get "/api/stats/stream" do
    if nodeinfo_monitor_enabled?(),
      do: StatsController.stream(conn, []),
      else: send_resp(conn, 404, "")
  end

  # ── Health + metrics ─────────────────────────────────────────────────────

  get "/up" do
    send_resp(conn, 200, "ok")
  end

  get "/metrics" do
    PromEx.Plug.call(conn, PromEx.Plug.init(prom_ex_module: SukhiFedi.PromEx))
  end

  # Token-guarded JSON metrics for offline analysis (history time series
  # + live snapshot). Separate from the open Prometheus `/metrics` above:
  # bearer auth via `:metrics_token`, 404 when unconfigured.
  get "/api/metrics" do
    MetricsController.show(conn, [])
  end

  # ── Mastodon/Misskey REST API — dispatched to plugin nodes ───────────────
  #
  # `SukhiFedi.Web.PluginPlug` forwards the request to one of the plugin
  # Erlang nodes listed in `config :sukhi_fedi, :plugin_nodes`. Each
  # plugin node runs the `:sukhi_api` application (see the top-level
  # `api/` directory) and exposes capabilities via `:rpc`. If no plugin
  # node is reachable the client gets a 503.

  # Streaming WebSocket lives in the gateway (Bandit upgrade), not on a
  # plugin node: the `:streaming` addon already holds the NATS listener
  # and the broadcaster Registry here, so the socket just verifies the
  # bearer and subscribes. Must precede the `/api/v1/*_` forwarder below,
  # which would otherwise ship the upgrade to a plugin that can't speak WS.
  get "/api/v1/streaming" do
    if SukhiFedi.Addon.Registry.enabled?(:streaming),
      do: StreamingController.connect(conn, []),
      else: send_resp(conn, 404, "")
  end

  # SSE counterparts (Mastodon's EventSource transport). Same `:home`
  # broadcaster feed as the WebSocket `user` stream; deliver Mastodon
  # `notification` events (follow / favourite / mention / reaction).
  get "/api/v1/streaming/user" do
    if SukhiFedi.Addon.Registry.enabled?(:streaming),
      do: StreamingSseController.user(conn, []),
      else: send_resp(conn, 404, "")
  end

  get "/api/v1/streaming/user/notification" do
    if SukhiFedi.Addon.Registry.enabled?(:streaming),
      do: StreamingSseController.user_notification(conn, []),
      else: send_resp(conn, 404, "")
  end

  # WebTransport の発券口（karutte のエッジへ）。gateway が bearer を検証して署名チケットを
  # 返すだけ＝プラグインノードに流さない。`/api/v1/*_` forwarder より前に置く。
  get "/api/wt" do
    SukhiFedi.Web.WtController.wt(conn, [])
  end

  # 路線図ページ（SPA `/map`）の公開の数字口。粗い累積カウンタだけなので
  # 認証なし。gateway が NATS/Postgres を直接持つのでここで完結する。
  get "/api/map" do
    SukhiFedi.Web.MapController.show(conn, [])
  end

  match "/api/v1/*_" do
    SukhiFedi.Web.PluginPlug.call(conn, SukhiFedi.Web.PluginPlug.init([]))
  end

  match "/api/admin/*_" do
    SukhiFedi.Web.PluginPlug.call(conn, SukhiFedi.Web.PluginPlug.init([]))
  end

  # v2 (search 等) も同じプラグインノードに流す。Mastodon は v1/v2 を
  # 混ぜて持つので、v2 だけ別出口にすると capability ファイルだけ
  # 増えて見えなくなる、という事故が起きる(実際 v0.1.65 で起きた)。
  match "/api/v2/*_" do
    SukhiFedi.Web.PluginPlug.call(conn, SukhiFedi.Web.PluginPlug.init([]))
  end

  # OAuth 2.0 server endpoints (`/oauth/authorize`, `/oauth/token`,
  # `/oauth/revoke`) live on the api plugin node. PluginPlug is
  # path-agnostic so the same forwarder handles them.
  match "/oauth/*_" do
    SukhiFedi.Web.PluginPlug.call(conn, SukhiFedi.Web.PluginPlug.init([]))
  end

  # SPA のプロフィール画面 (`/@alice`, `/@alice@example.tld`,
  # `/@alice/followers`, `/@alice/following`) は `/@` プレフィクスで
  # 来る。ActivityPub の actor URL は `/users/:name` 側に分けてあるので
  # 衝突しない。Plug.Router の `*glob` は segment の先頭にしか書けず、
  # `/@` で始まる任意のパスを 1 行で書けないので、catch-all の中で
  # 文字列マッチして SPA に渡す。
  match _ do
    if String.starts_with?(conn.request_path, "/@") do
      serve_at_path(conn)
    else
      send_resp(conn, 404, "not found")
    end
  end

  # `/@alice` (profile) and `/@alice/123` (a note) are SPA routes. For an
  # app client we serve the SPA shell as before; for a crawler / no-JS GET
  # with the preview enabled we render the same HTML the actor/note routes
  # do, by re-deriving the `:name`/`:note_id` path params from the URL (the
  # `*glob` can't bind a `/@`-leading segment, so we split here). Any other
  # `/@…` path (followers/following) keeps falling through to the shell.
  defp serve_at_path(conn) do
    if PublicPreviewController.wants_html_preview?(conn) do
      case path_segments(conn) do
        ["@" <> username] ->
          PublicPreviewController.profile(put_path_param(conn, "name", username))

        ["@" <> username, id] ->
          conn
          |> put_path_param("name", username)
          |> put_path_param("note_id", id)
          |> PublicPreviewController.note()

        _ ->
          serve_spa(conn)
      end
    else
      serve_spa(conn)
    end
  end

  defp path_segments(conn) do
    conn.request_path |> String.trim_leading("/") |> String.split("/", trim: true)
  end

  defp put_path_param(conn, key, value) do
    %{conn | path_params: Map.put(conn.path_params, key, value)}
  end

  defp wants_activity_json?(conn) do
    conn
    |> get_req_header("accept")
    |> List.first()
    |> then(fn
      accept when is_binary(accept) ->
        String.contains?(accept, "application/activity+json") or
          String.contains?(accept, "application/ld+json")

      _ ->
        false
    end)
  end

  defp redirect_to_ap_object(conn, id_raw) do
    with {id, ""} <- Integer.parse(id_raw || ""),
         {:ok, ap_id} <- SukhiFedi.Addons.Deco.ap_id_for_post(id) do
      conn
      |> put_resp_header("location", ap_id)
      |> send_resp(302, "")
    else
      _ -> send_resp(conn, 404, "")
    end
  end

  defp serve_spa(conn) do
    # index.html refers to content-hashed chunks (`_app/immutable/...`).
    # If a CDN (Cloudflare here) caches the HTML, the browser keeps
    # asking for old chunk names and never sees a new SPA push. Force
    # revalidation on the shell; the chunks themselves are
    # cache-forever-safe because their URL changes per build.
    override_root = System.get_env("STATIC_OVERRIDE_DIR", "/app/priv/static-override")
    baked_root = Path.join([:code.priv_dir(:sukhi_fedi), "static"])

    index = pick_fresher(override_root, baked_root, "index.html")

    if index do
      conn
      |> put_resp_content_type("text/html; charset=utf-8")
      |> put_resp_header("cache-control", "no-cache, must-revalidate")
      |> send_file(200, index)
    else
      send_resp(conn, 404, "frontend not built — run `cd web && npm run build`")
    end
  end

  defp serve_static(conn, path_segments) do
    if Enum.any?(path_segments, &(&1 == "..")) do
      send_resp(conn, 400, "")
    else
      relative = Path.join(path_segments)
      # `:code.priv_dir/1` returns the versioned release path
      # (/app/lib/sukhi_fedi-<vsn>/priv), which would force the
      # deploy.yml bind-mount target to change on every release.
      # Read the override location from env instead — defaults to the
      # container's /app/priv/static-override, where the kamal
      # accessory bind-mounts the host's /var/lib/sukhi-fedi/static.
      override_root = System.get_env("STATIC_OVERRIDE_DIR", "/app/priv/static-override")
      baked_root = Path.join([:code.priv_dir(:sukhi_fedi), "static"])

      # 両方に同じ path があるときは mtime が新しいほうを返す。
      # 以前は override 先勝ちだったので、古い `make push-static` の
      # 残骸が新しい kamal deploy の baked を覆い隠す事故があった。
      case pick_fresher(override_root, baked_root, relative) do
        nil ->
          send_resp(conn, 404, "")

        full ->
          conn
          |> put_resp_content_type(content_type_for(full))
          |> put_static_cache_control(relative)
          |> send_file(200, full)
      end
    end
  end

  # serve_spa のコメントで「chunks は cache-forever-safe」と言っておきながら
  # ヘッダを付け忘れていた ─ CF が BYPASS して毎回 origin まで来ていた。
  # `_app/immutable/` は content-hash 付きなので永久キャッシュ、twemoji は
  # 名前が安定(package 更新時だけ変わる)なので一日。それ以外は触らない。
  defp put_static_cache_control(conn, relative) do
    cond do
      String.starts_with?(relative, "_app/immutable/") ->
        put_resp_header(conn, "cache-control", "public, max-age=31536000, immutable")

      String.starts_with?(relative, "twemoji/") ->
        put_resp_header(conn, "cache-control", "public, max-age=86400")

      true ->
        conn
    end
  end

  defp safe_regular?(root, relative) do
    full = Path.join(root, relative)

    String.starts_with?(Path.expand(full), Path.expand(root)) and File.regular?(full)
  end

  # override と baked のうち、両方あれば mtime が新しいほう、片方しか
  # 無ければそれ、どちらも無ければ nil を返す。
  #
  # natadeco は sukhi-fedi と同じ combined image を相乗りしているので、
  # baked 側には(natadeco が一度も使うつもりのない)sukhi 自身の
  # フロントエンドが常に焼き込まれている。mtime 勝負のままだと、
  # combined を焼き直すたびに baked の mtime が新しくなり、override の
  # 再同期を一手間忘れただけで sukhi の画面に差し戻ってしまう(実際に
  # 起きた)。`STATIC_OVERRIDE_ONLY=true` で baked 側を最初から候補から
  # 外せるようにして、「どちらの画面を出すか」を mtime 任せではなく
  # 明示に決められるようにする。
  defp pick_fresher(override_root, baked_root, relative) do
    override_ok = safe_regular?(override_root, relative)
    baked_ok = not override_only?() and safe_regular?(baked_root, relative)

    cond do
      override_ok and baked_ok ->
        override_path = Path.join(override_root, relative)
        baked_path = Path.join(baked_root, relative)
        if mtime(override_path) >= mtime(baked_path), do: override_path, else: baked_path

      override_ok ->
        Path.join(override_root, relative)

      baked_ok ->
        Path.join(baked_root, relative)

      true ->
        nil
    end
  end

  defp override_only?, do: System.get_env("STATIC_OVERRIDE_ONLY") == "true"

  defp mtime(path) do
    case File.stat(path, time: :posix) do
      {:ok, %File.Stat{mtime: t}} -> t
      _ -> 0
    end
  end

  # `/uploads/<key>` を S3 backend (rustfs) から proxy する。avatar /
  # 添付などはすべてここを通る。key は upload パイプラインが生成する
  # ランダムバイト列なので traversal は事実上不可だが、`..` segment は
  # 念のため弾く。S3 未設定の env では 503 を返す(本番でしか効かない経路)。
  defp serve_upload(conn, path_segments) do
    cond do
      Enum.any?(path_segments, &(&1 == "..")) ->
        send_resp(conn, 400, "")

      not s3_enabled?() ->
        send_resp(conn, 503, "media backend not configured")

      true ->
        key = Enum.join(path_segments, "/")
        proxy_from_s3(conn, key)
    end
  end

  defp proxy_from_s3(conn, key) do
    case ExAws.S3.get_object(s3_bucket(), key) |> ExAws.request() do
      {:ok, %{body: body, headers: headers}} ->
        ct = header_value(headers, "content-type") || content_type_for(key)

        conn
        |> put_resp_content_type(ct)
        # Upload keys are random and content-addressed by birth — a given
        # `/uploads/<key>` never changes — so let browsers and any CDN in
        # front cache it hard instead of re-proxying the full bytes
        # through the BEAM from rustfs on every view.
        |> put_resp_header("cache-control", "public, max-age=31536000, immutable")
        # Media is data, never executable. Lock the response down so an
        # uploaded `.html` / `.svg` can't run script in our origin, stop
        # MIME sniffing, and force non-media types to download rather than
        # render as a page. (Overrides the gateway's general CSP.)
        |> put_resp_header("content-security-policy", "default-src 'none'; sandbox")
        |> put_resp_header("x-content-type-options", "nosniff")
        |> put_resp_header("content-disposition", media_disposition(ct))
        |> send_resp(200, body)

      {:error, {:http_error, 404, _}} ->
        send_resp(conn, 404, "")

      {:error, reason} ->
        require Logger
        Logger.warning("serve_upload: s3 get_object failed key=#{key} reason=#{inspect(reason)}")
        send_resp(conn, 502, "")
    end
  end

  # Real media renders inline; anything else (an uploaded text/html or
  # image/svg+xml, which can carry script) is forced to download so it
  # can't render as a page in our origin.
  defp media_disposition("image/svg+xml"), do: "attachment"
  defp media_disposition("image/" <> _), do: "inline"
  defp media_disposition("video/" <> _), do: "inline"
  defp media_disposition("audio/" <> _), do: "inline"
  defp media_disposition(_), do: "attachment"

  defp header_value(headers, name) when is_list(headers) do
    target = String.downcase(name)

    Enum.find_value(headers, fn
      {k, v} -> if String.downcase(to_string(k)) == target, do: v
      _ -> nil
    end)
  end

  defp header_value(_, _), do: nil

  defp s3_enabled?, do: Application.get_env(:sukhi_fedi, :s3, [])[:enabled] == true
  defp s3_bucket, do: Application.get_env(:sukhi_fedi, :s3, [])[:bucket] || "media"

  defp content_type_for(path) do
    case Path.extname(path) |> String.downcase() do
      ".png" -> "image/png"
      ".jpg" -> "image/jpeg"
      ".jpeg" -> "image/jpeg"
      ".gif" -> "image/gif"
      ".webp" -> "image/webp"
      ".svg" -> "image/svg+xml"
      ".ico" -> "image/x-icon"
      ".mp4" -> "video/mp4"
      ".webm" -> "video/webm"
      ".mp3" -> "audio/mpeg"
      ".ogg" -> "audio/ogg"
      # SvelteKit ビルド成果物。.js は ES module として読まれるので
      # text/javascript が必須(application/octet-stream だと browser
      # が module load を拒否する)。
      ".js" -> "text/javascript"
      ".mjs" -> "text/javascript"
      ".css" -> "text/css"
      ".html" -> "text/html; charset=utf-8"
      ".json" -> "application/json"
      ".map" -> "application/json"
      # PWA の manifest。octet-stream だと browser が読まずに捨てる。
      ".webmanifest" -> "application/manifest+json"
      ".woff" -> "font/woff"
      ".woff2" -> "font/woff2"
      ".ttf" -> "font/ttf"
      _ -> "application/octet-stream"
    end
  end

  # Reads the addon config at request time — set via env vars in
  # config/runtime.exs (ENABLED_ADDONS, DISABLE_ADDONS, ADDON_PRESETS).
  defp nodeinfo_monitor_enabled? do
    enabled = Application.get_env(:sukhi_fedi, :enabled_addons, :all)
    disabled = Application.get_env(:sukhi_fedi, :disabled_addons, [])

    cond do
      :nodeinfo_monitor in disabled -> false
      enabled == :all -> true
      true -> :nodeinfo_monitor in enabled
    end
  end
end
