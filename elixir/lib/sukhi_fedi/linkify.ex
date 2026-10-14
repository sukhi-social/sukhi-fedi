# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Linkify do
  @moduledoc """
  `@だれか` と `#なにか` を、リンクに変える。

  ここで書かれた投稿は、いままで平文のままだった ── 「@nyanrus」も
  「#散歩」も、ただの文字。よそから来た投稿には h-card がついているので
  画面では違いが出ていて、それが「自分のところの投稿だけリンクにならない」
  という形で出ていた。

  出す形は Mastodon と同じ。連合の向こうもここも、同じものを読む:

      <span class="h-card"><a href="…" class="u-url mention">@<span>name</span></a></span>
      <a href="/tags/散歩" class="mention hashtag" rel="tag">#<span>散歩</span></a>

  ## ひとつの走査で、両方いっしょに

  順に二回かけたくなるけれど、それは駄目。一回目が入れたリンクの中を
  二回目が読んでしまう ── `#tag` を入れたあとに `@` を探すと、URL の中の
  文字を掴む。だから一度で、片方ずつ確定させながら進む。

  ## タグの中は見ない

  `<a>` や `<code>` の中身は触らない。リンクの中にリンクは作れないし、
  コードの中の `#include` はタグではない。属性値(href の中など)も同じ。

  ## ネットには出ない

  知らない handle は、平文のまま置く。ここは投稿を書くたびに通る道なので、
  知らない名前ひとつで、相手の選んだホストへ WebFinger しに行くわけには
  いかない。**リンクにならないのは、壊れているのではなく、知らないだけ。**

  ## 走査と、描画

  HTML を「そのまま残す所」「`@` の候補」「`#` の候補」に切るところは
  `SukhiFedi.Linkify.Scanner`(純粋な走査。実装は `SukhiFedi.Backend` で
  差し替えられる)。ここは、その切れ端を受けて、知っている人ならリンクに、
  知らなければ平文のまま書く側 ── DB を引くのも、HTML を組むのも。
  """

  @doc """
  HTML の中の言及とタグを、リンクにする。

  `lookup` は handle(`"name"` か `"name@host"`)を受けて
  `%{acct: …, url: …}` か nil を返す関数。nil なら平文のまま。
  """
  @spec run(term(), (String.t() -> %{acct: String.t(), url: String.t()} | nil)) :: term()
  def run(html, lookup) when is_binary(html) and is_function(lookup, 1) do
    :linkify_scanner
    |> SukhiFedi.Backend.call(:scan, [html])
    |> Enum.map_join(fn
      {:raw, text} -> text
      {:mention, raw, user, host} -> mention_html(raw, user, host, lookup)
      {:hashtag, _raw, tag} -> hashtag_html(tag)
    end)
  end

  def run(other, _lookup), do: other

  @doc """
  ふだんの探しかた。**ネットには出ない。**

  ここにいる人か、もう知っている遠くの人だけ。知らない handle のために
  WebFinger しに行くと、投稿を書くたびに、相手の選んだホストへこちらから
  出ていくことになる。それは配達のときだけでいい道。
  """
  @spec known_account(String.t()) :: %{acct: String.t(), url: String.t()} | nil
  def known_account(handle) do
    case SukhiFedi.Accounts.lookup_by_acct(handle, resolve: false) do
      {:ok, account} -> as_link(account)
      {:error, _} -> nil
    end
  end

  defp as_link(account) do
    domain = SukhiFedi.Config.domain!()
    acct = if account.domain, do: "#{account.username}@#{account.domain}", else: account.username

    url =
      cond do
        is_binary(Map.get(account, :actor_uri)) and account.domain -> account.actor_uri
        true -> "https://#{domain}/@#{acct}"
      end

    %{acct: acct, url: url}
  end

  defp mention_html(raw, user, host, lookup) do
    handle = if host == nil, do: user, else: "#{user}@#{host}"

    case lookup.(handle) do
      %{url: url} when is_binary(url) ->
        ~s|<span class="h-card"><a href="#{esc(url)}" class="u-url mention">@<span>#{esc(user)}</span></a></span>|

      _ ->
        # 知らない名前。平文のまま置く ── リンクにならないのは、壊れて
        # いるのではなく、知らないだけ。
        raw
    end
  end

  defp hashtag_html(tag) do
    ~s|<a href="/tags/#{URI.encode(String.downcase(tag))}" class="mention hashtag" rel="tag">#<span>#{esc(tag)}</span></a>|
  end

  defp esc(s), do: Plug.HTML.html_escape(s)
end
