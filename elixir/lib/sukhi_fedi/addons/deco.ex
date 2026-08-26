# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Addons.Deco do
  @moduledoc """
  Deco addon — natadeco の掲示板。板一枚が「デコ」で、投稿は既存の
  `notes` に相乗りする（`deco_notes` は「どの板か」だけを持つ）。

  書いた人は隠さない。note.com と同じで、板の上でもその人の名前と
  ハンドルがそのまま出る ── 名前のうしろに立てば、書いたものは自分の
  ものになる。

  ここが持つのは器だけ。本文・HTML 化・タグ・メディア・削除は
  `SukhiFedi.Notes` のまま ── 同じものの道を二本作らないため。

  板は Group actor(`{slug}-deco@domain`)を持てる ── 個人アカウントの
  username はハイフンを使えないので、この形は名前空間が構造的に
  ぶつからない。actor JSON は `SukhiFedi.AP.GroupJson` が組む。
  いまは actor が引ける・webfinger で見つかるところまで(フォローの
  受理・Announce 中継はまだ先の段)。表札(`has_actor`)を出さない板は
  鍵を持たず、`get_actor_record/1` が `:not_found` を返す。

  ## 読むのは、いつでも誰でも

  `local_only` も `has_actor` も、決めているのは **どこまで届くか** で
  あって、**誰が読めるか** ではない。前者は書いたものが外の網に出るか、
  後者は場が外から見つかるか。どちらが false でも、natadeco に来た人が
  読めるものは変わらない ── 読む口(`list_decos/0`・`list_posts/2`・
  `get_post/2`)はトークンを要らないし、viewer で絞りもしない。
  `viewer_id` を受けるのは反応の `me` を立てるためだけで、見えるものの
  数は viewer で変わらない。

  完全に閉じた板は、作れない構造にしてある。鍵をかけたくなったときは、
  それは掲示板ではない別のものを作っている ── あたたかいものは、
  隠さなくていいので。

  この約束は `test/integration/deco_test.exs` の「隠れた板は作れない」
  で留めてある。ここに viewer の絞りを足すと、あそこが落ちる。

  ## どこに何が居るか

    * `Deco.Boards` — 板そのもの(立てる・消す・話題・知らせ・既読)
    * `Deco.Posts` — 板の上に書かれたもの(立てる・返す・直す・読む)
    * `Deco.Federation` — 外の網と(ベランダ・追う人・Announce・結ぶ)
    * `Deco.View` — 板と人の、外に手渡すときの形

  このモジュール自身は口だけ。api ノードが `:rpc` でモジュール名と
  関数名を組にして呼んでくるので、分けたことが向こうに漏れないよう、
  名前はここに揃えてある。
  """

  use SukhiFedi.Addon, id: :deco

  alias SukhiFedi.Addons.Deco.{Boards, Federation, Posts}

  # ── 板 ───────────────────────────────────────────────────────────────
  #
  # 中身は `Deco.Boards`。ここに名前だけ残すのは、api ノードが
  # `:rpc` でこのモジュール名と関数名を組にして呼んでくるから ──
  # 分けたことが向こうに漏れないように、口はここに揃えておく。

  defdelegate list_decos(viewer_id \\ nil), to: Boards
  defdelegate set_topic(account, slug, topic), to: Boards
  defdelegate set_notify(account, slug, notify), to: Boards
  defdelegate seen(account, slug), to: Boards
  defdelegate get_deco(slug), to: Boards
  defdelegate get_actor_record(slug), to: Boards
  defdelegate get_deco_record(slug), to: Boards
  defdelegate create_deco(account_or_id, attrs), to: Boards
  defdelegate delete_deco(slug), to: Boards

  # ── 書く・直す・読む ─────────────────────────────────────────────
  #
  # 中身は `Deco.Posts`。

  defdelegate post(author, slug, params), to: Posts
  defdelegate reply(author, note_id, params), to: Posts
  defdelegate update_post(author, note_id, params), to: Posts
  defdelegate delete_post(author, note_id), to: Posts
  defdelegate report_post(reporter, note_id, comment \\ nil), to: Posts
  defdelegate list_posts(slug, opts \\ []), to: Posts
  defdelegate list_flow(slug, opts \\ []), to: Posts
  defdelegate ap_id_for_post(note_id), to: Posts
  defdelegate get_post(note_id, viewer_id \\ nil), to: Posts

  # ── 外の網と ─────────────────────────────────────────────────────
  #
  # 中身は `Deco.Federation`。

  defdelegate peek(handle_or_uri), to: Federation
  defdelegate announce_new_post(deco_id, note_id), to: Federation
  defdelegate record_follow(deco_actor_uri, follower_uri, inbox_url), to: Federation
  defdelegate drop_follow(deco_actor_uri, follower_uri), to: Federation
  defdelegate follower_inboxes(deco_id), to: Federation
  defdelegate follower_uris(slug), to: Federation
  defdelegate wire_info(note_id), to: Federation
  defdelegate bind_inbound(note_id, raw), to: Federation
end
