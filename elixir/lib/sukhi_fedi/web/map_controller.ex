# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Web.MapController do
  @moduledoc """
  `GET /api/map` — 路線図ページ（SPA `/map`）が列車を走らせるための公開の数字口。

  返すのは粗い数と現在時刻だけ:

    * outbox 表の通し番号（最新の行 id）と、まだ渡していない行の数
    * 待避線 ── 配達をあきらめた便の数（`SukhiFedi.Metrics.dlq_depth/0`）
    * この 1 日に生まれた note の数（ローカル / リモート別）
    * この 1 日に連合へ届けた便の数（delivery_receipts の delivered）
    * 宇宙図の星（`SukhiFedi.MapPeers` の allow-list に載る domain と、
      そこからこの 1 日に届いた note の数）— 管理人が選んだ星だけ

  1 日基準なのは、しずかな星でも「この星の一日」が見えるように。
  宛先・本文・アカウントは含まれないので認証なしで開けてよく、
  `/api/*` は Anubis も素通し。無認証の口なので、結果を短く（5 秒）持ち回して
  訪問者の数だけ DB を叩かないようにしている。

  `METRICS_TOKEN` 門番つきの `GET /api/metrics`（ホスト資源の歴史）とは別物。
  こちらは「いま、どの線路を、どのくらい列車が走っているか」だけ。
  """

  import Ecto.Query
  import Plug.Conn

  alias SukhiFedi.MapPeers
  alias SukhiFedi.Metrics
  alias SukhiFedi.Repo
  alias SukhiFedi.Schema.{Note, OutboxEvent}
  @cache_ms 5_000
  @window_hours 24

  def show(conn, _opts) do
    conn
    |> put_resp_content_type("application/json")
    |> put_resp_header("cache-control", "public, max-age=5")
    |> send_resp(200, JSON.encode!(payload()))
  end

  # 直近の結果を :persistent_term に持ち回す。無認証の口が DB の
  # 直通にならないための、いちばん小さい弁。
  defp payload do
    now = System.monotonic_time(:millisecond)

    case :persistent_term.get({__MODULE__, :cache}, nil) do
      {at, body} when now - at < @cache_ms ->
        body

      _ ->
        body = build()
        :persistent_term.put({__MODULE__, :cache}, {now, body})
        body
    end
  end

  defp build do
    since = DateTime.add(DateTime.utc_now(), -@window_hours * 3600, :second)

    %{
      at: DateTime.utc_now() |> DateTime.to_iso8601(),
      streams: %{outbox: outbox_state(), outbox_dlq: siding_state(), events: nil},
      notes_24h: recent_notes(since),
      deliveries_24h: recent_deliveries(since),
      peers: peers(since)
    }
  end

  # 宇宙図の星。allow-list の domain だけ、この 1 日に届いた note 数を添えて。
  # リストに無い星は数字ごと出さない(ホワイトリスト式)。
  defp peers(since) do
    domains = MapPeers.domains()

    counts =
      if domains == [] do
        %{}
      else
        from(n in Note,
          where: n.created_at > ^since and n.domain in ^domains,
          group_by: n.domain,
          select: {n.domain, count(n.id)}
        )
        |> Repo.all()
        |> Map.new()
      end

    Enum.map(domains, fn d -> %{domain: d, notes_24h: Map.get(counts, d, 0)} end)
  end

  # 連合線。`seq` は outbox 表の通し番号、`held` はまだ渡していない行
  # （ふだんは 0 ── Relay が NOTIFY で即つかむ）。数字が取れないときは
  # nil のまま返す＝ページ側はその線を「運転見合わせ」にする。
  defp outbox_state do
    from(e in OutboxEvent,
      select: {coalesce(max(e.id), 0), filter(count(e.id), e.status == "pending")}
    )
    |> Repo.one()
    |> case do
      {seq, held} -> %{seq: seq, held: held}
      _ -> nil
    end
  rescue
    _ -> nil
  end

  # 待避線。あきらめた便が停まっている数。累計＝いまの数なので seq と
  # held は同じ（Oban の discarded は掃かれずに残る）。
  defp siding_state do
    case Metrics.dlq_depth() do
      n when is_integer(n) -> %{seq: n, held: n}
      _ -> nil
    end
  end

  # `events` は DOMAIN_EVENTS の名残り。streaming の実配線は plain NATS の
  # `stream.new_post` で数を刻まないので、ここでは数えられない（ページ側は
  # この 1 日の note 数で場内放送を描いている）。キーだけ残して nil。

  defp recent_notes(since) do
    rows =
      from(n in Note,
        where: n.created_at > ^since,
        group_by: is_nil(n.domain),
        select: {is_nil(n.domain), count(n.id)}
      )
      |> Repo.all()
      |> Map.new()

    %{local: Map.get(rows, true, 0), remote: Map.get(rows, false, 0)}
  end

  # delivery_receipts は delivery アプリの表だが DB は共有。schema を
  # 持ち込まず schemaless で数だけ見る（列は naive timestamp なので合わせる）。
  defp recent_deliveries(since) do
    since_naive = DateTime.to_naive(since)

    from(r in "delivery_receipts",
      where: r.delivered_at > ^since_naive and r.status == "delivered",
      select: count(r.id)
    )
    |> Repo.one()
  end
end
