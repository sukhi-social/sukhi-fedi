# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Addons.Deco.View do
  @moduledoc """
  板と、板の上に名前が出る人の、外に手渡すときの形。

  板そのものを返す口は一つではない ── 一覧、一枚、話題を置いたあと、
  作った直後、消す直前、そして外から覗いたベランダ。どれも同じ板を
  返しているのに形がずれると、読む側は「同じものだ」と気づけない。
  だからここに一枚だけ置いて、全部そこを通す。

  `post_count` を引数で受けるのは、数えかたが呼ぶ場所ごとに違うから
  ── 一覧はまとめて一度に数え、一枚はその板だけ数える。ここで数えると
  一覧が板の数だけクエリを撃つことになる。
  """

  alias SukhiFedi.Repo
  alias SukhiFedi.Schema.{Account, Deco}

  @doc "板一枚の形。`post_count` は呼び出し側が数えて渡す。"
  def deco(%Deco{} = d, post_count) do
    %{
      id: d.id,
      slug: d.slug,
      name: d.name,
      name_i18n: d.name_i18n || %{},
      description: d.description,
      description_i18n: d.description_i18n || %{},
      local_only: d.local_only || false,
      has_actor: d.has_actor,
      kind: d.kind || "thread",
      topic: d.topic,
      topic_by: topic_by(d),
      topic_at: d.topic_at,
      post_count: post_count,
      created_at: d.created_at
    }
  end

  @doc """
  書いた人の形。natadeco は書いた人を隠さないので、板の上でも
  投稿の上でも、ここが返すのと同じ名前とハンドルが出る。
  """
  def author(%Account{} = a) do
    %{
      username: a.username,
      acct: if(a.domain, do: "#{a.username}@#{a.domain}", else: a.username),
      display_name: a.display_name || a.username,
      avatar_url: a.avatar_url
    }
  end

  defp topic_by(%Deco{topic_by_id: nil}), do: nil

  defp topic_by(%Deco{topic_by_id: id}) do
    case Repo.get(Account, id) do
      %Account{} = a -> author(a)
      nil -> nil
    end
  end
end
