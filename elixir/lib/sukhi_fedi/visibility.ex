# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Visibility do
  @moduledoc """
  「どこまで見せるか」の一覧を、名前で呼べるようにする。

  いままで、この一覧は八箇所に手で書かれていた。しかも二種類あるのに、
  見た目がほとんど同じ:

      ["public", "unlisted", "followers"]   # DM だけ外す
      ["public", "unlisted"]                # 誰にでも見せるものだけ

  どちらの意味なのかは、周りのコードを読まないと分からない。
  そして**書き忘れると、何も起きない** ── クエリは通るし、行も返る。
  ただ、返ってはいけないものが混ざっているだけ。

  実際そうなった。`Accounts.counts_for/1` だけがこの切りかたから漏れて
  いて、プロフィールの投稿数に DM が入っていた。中身は見えないけれど
  「何通送ったか」は誰でも数えられる状態が、ずっと続いていた。
  timelines も lists も self_cleanup も正しかったので、**揃っていない
  ことに誰も気づけなかった**。

  だから名前をつける。`not_direct()` と書いてあれば、書き忘れは
  「一覧が違う」ではなく「関数を呼んでいない」になって、目に入る。
  """

  @doc """
  DM 以外ぜんぶ。**「その人の投稿」と言えるもの**の範囲。

  フォロワー限定も入る ── 見える人には見える投稿なので、投稿ではある。
  DM は、少ない相手に向けた投稿ではなく、手紙。
  """
  @spec not_direct() :: [String.t()]
  def not_direct, do: ["public", "unlisted", "followers"]

  @doc """
  誰にでも見せるもの。ログインしていない人に出していい範囲。

  `unlisted` が入るのは、あれが「公開だが一覧に載せない」だから ──
  見せない、ではない。
  """
  @spec public_only() :: [String.t()]
  def public_only, do: ["public", "unlisted"]

  @doc "この鯖が受け付ける、ぜんぶ。"
  @spec all() :: [String.t()]
  def all, do: ["public", "unlisted", "followers", "direct"]

  @doc "手紙か。"
  @spec direct?(String.t() | nil) :: boolean()
  def direct?(v), do: v == "direct"
end
