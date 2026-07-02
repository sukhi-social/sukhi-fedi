# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Web.MapController do
  @moduledoc """
  `GET /api/map` — 路線図ページ（SPA `/map`）が列車を走らせるための公開の数字口。

  返すのは粗い累積カウンタと現在時刻だけ:

    * JetStream 各 stream の `last_seq`（累積通し番号）と滞留数
      （OUTBOX / OUTBOX_DLQ / DOMAIN_EVENTS）
    * 直近 5 分に生まれた note の数（ローカル / リモート別）

  流量の計算はしない。ページ側が 2 回のポーリングの差分から出す＝サーバは
  無状態でいられる。宛先・本文・アカウントは含まれないので認証なしで開けてよく、
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
  @recent_minutes 5

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
    %{
      at: DateTime.utc_now() |> DateTime.to_iso8601(),
      streams: Map.new(@streams, fn {key, name} -> {key, stream_state(name)} end),
      notes_5m: recent_notes()
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

  defp recent_notes do
    since = DateTime.add(DateTime.utc_now(), -@recent_minutes * 60, :second)

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
end
