# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.AP.Titled do
  @moduledoc """
  題つきの投稿が、線の上でどう名乗るか。

  同じ note が二つの道で外へ出る ── 配るとき(`Fedi.Builders`)と、
  引かれるとき(`Web.NoteController`)。返信してきた相手のサーバは
  たいてい引きに来るので、片方だけ整えると、返信されたときにだけ
  題も板も消える、という見つけにくい形になる。だから組み立てはここ
  一箇所に置いて、両方がここを通る。

  ## 題が二度出るわけ

  `name` は掲示板を持つ実装(NodeBB / PieFed / Lemmy)が読む。
  Mastodon は `Note` の `name` を一度も読まないので、そちらには
  本文の頭に引用として置く ── ブーストされて文脈から離れたときも、
  これが付いていれば何の話か分かる。

  ## Article

  意味の上では題を持つものは `Article` だが、Mastodon は `Article` を
  CONVERTED_TYPES に入れていて `content` を一行も出さない。だから
  既定は `Note` で、`Article` は書いた人が選んだときだけ。選んだ
  ときは `summary` に書き出しを入れる ── 空だと題とリンクだけになり、
  長い文章として出したつもりが「文章が消えた」になる。
  """

  @excerpt_len 220

  @doc "題を持ち、書いた人が長い文章として選んだときだけ `Article`。"
  @spec type(boolean(), String.t() | nil) :: String.t()
  def type(as_article?, title), do: if(as_article? and titled?(title), do: "Article", else: "Note")

  @spec titled?(String.t() | nil) :: boolean()
  def titled?(t), do: is_binary(t) and String.trim(t) != ""

  @doc """
  本文の頭に「題 — @書いた人」を引用で置く。

  保存する本文には入れない ── natadeco の画面は題も名前ももう出して
  いるので、そこで二度読ませない。ここ(線の上)だけで足りる。
  """
  @spec content(String.t() | nil, String.t() | nil, String.t() | nil, String.t() | nil) ::
          String.t() | nil
  def content(html, title, handle, actor_uri) do
    if titled?(title), do: header(title, handle, actor_uri) <> (html || ""), else: html
  end

  @doc """
  `Article` の `summary` は、Mastodon では本文の代わりに出る場所。
  自分で CW を書いている人のぶんは触らない ── それはその人の言葉で、
  抜粋で上書きしていいものではない。
  """
  @spec summary(String.t() | nil, boolean(), String.t() | nil, String.t() | nil) ::
          String.t() | nil
  def summary(cw, as_article?, title, html) do
    cond do
      is_binary(cw) and cw != "" -> cw
      as_article? and titled?(title) -> excerpt(html)
      true -> nil
    end
  end

  @doc """
  書いた人を本物の `Mention` にする一枚。ただの文字だと、向こうで
  押しても誰にも行き着かない。

  自分宛てなので通知は増えない ── `Notes.Create.notify_local_mentions/1`
  は自分を弾くし、向こうから見れば書いた人は remote。
  """
  @spec mention(String.t() | nil, String.t() | nil) :: map() | nil
  def mention(handle, actor_uri) when is_binary(handle) and is_binary(actor_uri),
    do: %{"type" => "Mention", "href" => actor_uri, "name" => handle}

  def mention(_, _), do: nil

  @doc "`@name@domain` の形。"
  @spec handle(String.t()) :: String.t()
  def handle(username), do: "@#{username}@#{SukhiFedi.Config.domain!()}"

  defp header(title, handle, actor_uri) do
    who =
      case {handle, actor_uri} do
        {h, u} when is_binary(h) and is_binary(u) ->
          ~s( — <a href="#{esc(u)}" class="mention">#{esc(h)}</a>)

        _ ->
          ""
      end

    "<blockquote><p>#{esc(title)}#{who}</p></blockquote>"
  end

  defp excerpt(html) when is_binary(html) do
    text =
      html
      |> String.replace(~r{<[^>]*>}, " ")
      |> String.replace(~r{\s+}, " ")
      |> String.trim()

    if String.length(text) > @excerpt_len,
      do: String.slice(text, 0, @excerpt_len) <> "…",
      else: text
  end

  defp excerpt(_), do: nil

  defp esc(s) do
    s
    |> to_string()
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace(~s("), "&quot;")
  end
end
