# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Web.MapController do
  @moduledoc """
  `GET /api/map` — 路線図ページ（SPA `/map`）が列車を走らせるための公開の数字口。

  返すのは粗い数と現在時刻だけ:

    * JetStream 各 stream の `last_seq`（累積通し番号）と滞留数
      （OUTBOX / OUTBOX_DLQ / DOMAIN_EVENTS）
    * この 1 日に生まれた note の数（ローカル / リモート別）
    * この 1 日に連合へ届けた便の数（delivery_receipts の delivered）

  1 日基準なのは、しずかな星でも「この星の一日」が見えるように。
  宛先・本文・アカウントは含まれないので認証なしで開けてよく、
  `/api/*` は Anubis も素通し。無認証の口なので、結果を短く（5 秒）持ち回して
  訪問者の数だけ NATS/DB を叩かないようにしている。

  `METRICS_TOKEN` 門番つきの `GET /api/metrics`（ホスト資源の歴史）とは別物。
  こちらは「いま、どの線路を、どのくらい列車が走っているか」だけ。
  """

  import Ecto.Query
  import Plug.Conn

  alias SukhiFedi.Repo
  alias SukhiFedi.Schema.Note

  @streams %{outbox: "OUTBOX", outbox_dlq: "OUTBOX_DLQ", events: "DOMAIN_EVENTS"}
  @cache_ms 5_000
  @window_hours 24

  def show(conn, _opts) do
    conn
    |> put_resp_content_type("application/json")
    |> put_resp_header("cache-control", "public, max-age=5")
    |> send_resp(200, JSON.encode!(payload()))
  end

  # 直近の結果を :persistent_term に持ち回す。無認証の口が DB/NATS の
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
      streams: Map.new(@streams, fn {key, name} -> {key, stream_state(name)} end),
      notes_24h: recent_notes(since),
      deliveries_24h: recent_deliveries(since)
    }
  end

  # stream が無い / NATS に届かないときは nil のまま返す（ページ側は
  # その線を「運転見合わせ」表示にする）。Metrics.dlq_depth/0 と同じ守り。
  defp stream_state(name) do
    case Gnat.Jetstream.API.Stream.info(:gnat, name) do
      {:ok, %{state: %{messages: held, last_seq: seq}}} -> %{seq: seq, held: held}
      _ -> nil
    end
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

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
