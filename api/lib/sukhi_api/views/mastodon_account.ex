# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiApi.Views.MastodonAccount do
  @moduledoc """
  Render an `Account` (or a hydrated map projection) into Mastodon
  v1 Account JSON shape.

  Two render modes:
    * `render/2` — public Account (no `source` block, no scopes)
    * `render_credential/3` — CredentialAccount returned from
      `/api/v1/accounts/verify_credentials`. Includes `source` and
      Mastodon-specific oauth metadata.

  Counts are passed in separately because they're computed by a
  cached gateway helper and we don't want to recount on every
  render. `nil` counts render as `0`.
  """

  alias SukhiApi.Views.Id

  # 1x1 透明 PNG。header(バナー)の既定 ─ バナー無しは見えないままで
  # いい。avatar は @default_avatar_path(やさしいシルエット)を使う。
  @default_image "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII="

  # 画像が無い人の avatar の既定。web はこの URL を「画像なし」の印に
  # して頭文字 + 淡い色に描き替える ─ web/src/lib/avatar.ts と末尾を
  # 揃えること。他クライアントにはこのシルエットがそのまま見える。
  @default_avatar_path "/static/avatar-default.svg"

  @doc """
  Render a single account.

  `account` may be an `Account` struct or a plain map carrying the
  same keys; this is what comes off `:rpc` since structs survive the
  hop as maps.

  `counts` is `%{followers: int, following: int, statuses: int}` (any
  missing key defaults to 0).
  """
  @spec render(map() | nil, map()) :: map() | nil
  def render(account, counts \\ %{})
  def render(nil, _counts), do: nil

  def render(account, counts) do
    local_domain = SukhiApi.Config.domain!()
    username = account.username
    remote_domain = Map.get(account, :domain)

    # acct は Mastodon の慣習: local は "user"、remote は "user@host"。
    # url / uri は local なら自分のドメインで組み、remote なら
    # upsert 時に保存した canonical actor_uri を返す(無い古い行は
    # local 形式に fallback)。
    acct =
      if remote_domain in [nil, ""],
        do: username,
        else: "#{username}@#{remote_domain}"

    actor_uri =
      Map.get(account, :actor_uri) ||
        "https://#{local_domain}/users/#{username}"

    # Mastodon spec は avatar/header を「常に非 null の URL」と決めて
    # おり、Moshidon など Kotlin/Gson 系のクライアントは String non-null
    # で受けるので、null を返すと NPE で即クラッシュする。だから画像の
    # 無い人にも必ず既定 URL を返す:
    #   avatar … /static/avatar-default.svg(やさしいシルエット)。web は
    #            この URL を「画像なし」の印として頭文字 + 淡い色に描き
    #            替える。他クライアントにはシルエットがそのまま見える。
    #   header … バナー無しは何も無くていいので、見えない透明 PNG のまま。
    # リモートアカウントの画像は gateway の /proxy/{avatar,header}/:id に
    # 書き換える ─ 閲覧者の IP を相手サーバへ渡さないため。?v= は元 URL の
    # ハッシュで、actor 更新で画像 URL が変われば CF cache も自然に外れる。
    remote? = remote_domain not in [nil, ""]

    avatar =
      proxy_image(remote?, "avatar", account.id, Map.get(account, :avatar_url)) ||
        "https://#{local_domain}#{@default_avatar_path}"

    header =
      proxy_image(remote?, "header", account.id, Map.get(account, :banner_url)) ||
        @default_image

    %{
      id: Id.encode(account.id),
      username: username,
      acct: acct,
      display_name: Map.get(account, :display_name) || username,
      locked: Map.get(account, :locked, false) || false,
      bot: Map.get(account, :is_bot, false) || false,
      discoverable: Map.get(account, :discoverable, false) || false,
      indexable: Map.get(account, :indexable, false) || false,
      group: false,
      created_at: format_dt(Map.get(account, :created_at)),
      note: Map.get(account, :summary) || "",
      url: actor_uri,
      uri: actor_uri,
      avatar: avatar,
      avatar_static: avatar,
      header: header,
      header_static: header,
      followers_count: Map.get(counts, :followers, 0),
      following_count: Map.get(counts, :following, 0),
      statuses_count: Map.get(counts, :statuses, 0),
      last_status_at: nil,
      emojis: Map.get(account, :emojis) || [],
      fields: fields(account),
      # Account migration. `moved` is Mastodon's "this account has moved"
      # marker, rendered quietly as a link to the new identity (no number,
      # no banner — the truthful state, nothing more). `null` when not
      # moved. `aliases` is the person's declared "also me" set.
      moved: moved(Map.get(account, :moved_to_uri)),
      aliases: Map.get(account, :aliases) || []
    }
  end

  # A minimal account-shaped object pointing at the new identity. We don't
  # fetch the target per render (that would be an N+1 on every list); the
  # URI is enough for a client to show "moved to" and link through.
  defp moved(uri) when is_binary(uri) and uri != "" do
    handle = uri |> URI.parse() |> Map.get(:path, "") |> to_string() |> Path.basename()
    host = uri |> URI.parse() |> Map.get(:host)
    acct = if is_binary(host) and host != "", do: "#{handle}@#{host}", else: handle

    %{id: uri, acct: acct, username: handle, display_name: handle, url: uri, uri: uri}
  end

  defp moved(_), do: nil

  # Profile fields → Mastodon `fields`. Stored as `%{"name", "value"}`
  # rows (sanitized on write); `verified_at` is always nil — we don't run
  # rel="me" link verification, so we never claim a row is verified.
  defp fields(account) do
    case Map.get(account, :fields) do
      rows when is_list(rows) ->
        Enum.map(rows, fn row ->
          %{name: Map.get(row, "name", ""), value: Map.get(row, "value", ""), verified_at: nil}
        end)

      _ ->
        []
    end
  end

  defp proxy_image(true, kind, id, url) when is_binary(url) do
    SukhiApi.Views.ProxyUrl.profile_image(kind, id, url)
  end

  defp proxy_image(_remote?, _kind, _id, url), do: url

  @doc """
  Render `verify_credentials`-shaped CredentialAccount: extends a
  public Account with `source`, `role`, and a `scopes` echo.
  """
  @spec render_credential(map(), map(), [String.t()]) :: map()
  def render_credential(account, counts, scopes) do
    base = render(account, counts)

    Map.merge(base, %{
      source: %{
        privacy: "public",
        sensitive: false,
        language: nil,
        note: Map.get(account, :summary) || "",
        fields: fields(account),
        follow_requests_count: 0
      },
      role:
        if Map.get(account, :is_admin, false) do
          %{id: "1", name: "admin", permissions: "1", color: "", highlighted: true}
        else
          %{id: "0", name: "user", permissions: "0", color: "", highlighted: false}
        end,
      scopes: scopes
    })
  end

  @spec render_list([map()], map()) :: [map()]
  def render_list(accounts, counts_by_id \\ %{}) when is_list(accounts) do
    Enum.map(accounts, fn a -> render(a, Map.get(counts_by_id, a.id, %{})) end)
  end

  defp format_dt(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp format_dt(_), do: nil
end
