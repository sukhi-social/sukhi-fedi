# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiApi.Capabilities.MastodonSearch do
  @moduledoc """
  `GET /api/v2/search` (と互換のため `/api/v1/search` も) を提供する。

  返す形 (Mastodon 互換):
      %{accounts: [Account], hashtags: [Tag], statuses: [Status]}

  対応している `type`:
    * `accounts`  — local の username prefix、または `alice@host` の
                    remote 形式。`resolve=true` のとき WebFinger →
                    actor fetch → upsert で remote を立てる(初フォロー
                    に必要)。
    * `hashtags`  — local の tags.name prefix。
    * `statuses`  — いまは `[]`。本文 full-text 検索は別途
                    `OPEN_QUESTIONS.md#Q1` で設計中。

  `type` を省略すると上の三つを並列に当てる。
  `q` の先頭の `@` / `#` は素直に剥がして扱う。
  """

  use SukhiApi.Capability, addon: :mastodon_api

  alias SukhiApi.GatewayRpc
  alias SukhiApi.Views.MastodonAccount

  @impl true
  def routes do
    [
      {:get, "/api/v1/search", &search/1},
      {:get, "/api/v2/search", &search/1}
    ]
  end

  def search(req) do
    params = parse_query(req[:query])
    q = (params["q"] || "") |> String.trim()
    type = params["type"]
    # WebFinger を含む remote 解決は手間 + 外部 I/O なので、明示
    # `resolve=true` のときだけ走らせる(Mastodon と同じ)。
    resolve? = params["resolve"] in ["true", "1"]
    limit = parse_limit(params["limit"])

    cond do
      q == "" ->
        ok(200, %{accounts: [], hashtags: [], statuses: []})

      true ->
        accounts =
          if type in [nil, "accounts"],
            do: search_accounts(q, resolve?, limit),
            else: []

        hashtags =
          if type in [nil, "hashtags"],
            do: search_hashtags(q, limit),
            else: []

        ok(200, %{
          accounts: Enum.map(accounts, &render_account/1),
          hashtags: Enum.map(hashtags, &render_tag/1),
          statuses: []
        })
    end
  end

  # ── accounts ─────────────────────────────────────────────────────────────

  defp search_accounts(q, resolve?, limit) do
    bare = String.trim_leading(q, "@")

    cond do
      bare == "" ->
        []

      # `alice@example.tld` 形式 (host 部あり) → acct lookup に流す。
      # remote の場合は resolve? が true なら WebFinger で取りにいく。
      String.contains?(bare, "@") ->
        lookup_acct_one(bare, resolve?)

      # `alice` だけ → local の username prefix で複数返す。
      true ->
        case GatewayRpc.run(SukhiFedi.Accounts, :list_accounts, [
               %{username: bare, suspended: false},
               %{offset: 0, limit: limit}
             ]) do
          {:ok, {accounts, _total}} -> accounts
          _ -> []
        end
    end
  end

  defp lookup_acct_one(bare, resolve?) do
    case GatewayRpc.run(SukhiFedi.Accounts, :lookup_by_acct, [bare, [resolve: resolve?]]) do
      {:ok, account} -> [account]
      _ -> []
    end
  end

  defp render_account(account) do
    counts =
      case GatewayRpc.run(SukhiFedi.Accounts, :counts_for, [account.id]) do
        {:ok, %{} = m} -> m
        _ -> %{followers: 0, following: 0, statuses: 0}
      end

    MastodonAccount.render(account, counts)
  end

  # ── hashtags ─────────────────────────────────────────────────────────────

  defp search_hashtags(q, limit) do
    bare = String.trim_leading(q, "#")

    if bare == "" do
      []
    else
      case GatewayRpc.run(SukhiFedi.Tags, :search, [bare, [limit: limit]]) do
        {:ok, list} when is_list(list) -> list
        _ -> []
      end
    end
  end

  defp render_tag(tag) do
    domain = SukhiApi.Config.domain!()

    %{
      name: tag.name,
      url: "https://#{domain}/tags/#{tag.name}",
      # Mastodon は直近 1 週間の `[{day, uses, accounts}, ...]` を返すが、
      # まだ集計を持っていない。空配列で返す ─ クライアントは大体
      # null-safe に扱う。 [[mastodon-tag-history-tally]]
      history: [],
      following: false
    }
  end

  # ── helpers ──────────────────────────────────────────────────────────────

  defp parse_query(nil), do: %{}
  defp parse_query(""), do: %{}
  defp parse_query(q) when is_binary(q), do: URI.decode_query(q)

  defp parse_limit(nil), do: 20
  defp parse_limit(""), do: 20

  defp parse_limit(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} when n > 0 -> min(n, 40)
      _ -> 20
    end
  end

  defp parse_limit(n) when is_integer(n) and n > 0, do: min(n, 40)
  defp parse_limit(_), do: 20

  defp ok(status, body) do
    {:ok,
     %{
       status: status,
       body: JSON.encode!(body),
       headers: [{"content-type", "application/json"}]
     }}
  end
end
