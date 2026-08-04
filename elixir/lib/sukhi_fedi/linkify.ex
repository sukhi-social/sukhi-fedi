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
  """

  # `@user` / `@user@host`。直前が語なら掴まない(メールの尻尾を避ける)。
  @mention ~r/(?<![\w\/])@([\w]+)(?:@([\w.\-]+))?/u
  # `#tag`。**数字だけのタグは作らない** ── `#1` `#42` は番号のことが多く
  # (issue、部屋、順位)、それをタグにすると、書いた人の意図しない場所へ
  # 連れていく。だから、どこかに文字が要る。
  @hashtag ~r/(?<![\w\/&])#(?=[\p{L}\p{N}_-]*[\p{L}_])([\p{L}\p{N}_][\p{L}\p{N}_\-]*)/u

  @doc """
  HTML の中の言及とタグを、リンクにする。

  `lookup` は handle(`"name"` か `"name@host"`)を受けて
  `%{acct: …, url: …}` か nil を返す関数。nil なら平文のまま。
  """
  @spec run(term(), (String.t() -> %{acct: String.t(), url: String.t()} | nil)) :: term()
  def run(html, lookup) when is_binary(html) and is_function(lookup, 1) do
    html
    |> split_by_tags()
    |> Enum.map_join(fn
      {:tag, raw} -> raw
      {:skip, raw} -> raw
      {:text, raw} -> linkify_text(raw, lookup)
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

  # HTML を「タグ」「触らない範囲」「地の文」に切り分ける。
  #
  # 素朴だけれど、ここに来るのは Earmark が組んだ HTML だけで、人の書いた
  # ものではない ── そのあと必ず scrubber も通る。完全な parser を持つ
  # 理由がない。
  defp split_by_tags(html), do: scan(html, [])

  defp scan("", acc), do: Enum.reverse(acc)

  defp scan(rest, acc) do
    case :binary.match(rest, "<") do
      :nomatch ->
        Enum.reverse([{:text, rest} | acc])

      {0, _} ->
        {tag, after_tag} = take_tag(rest)
        name = tag_name(tag)

        if name in ~w(a code pre) and not String.starts_with?(tag, "</") do
          # この要素は、閉じるまで丸ごと触らない。
          {inner, tail} = take_until_close(after_tag, name)
          scan(tail, [{:skip, tag <> inner} | acc])
        else
          scan(after_tag, [{:tag, tag} | acc])
        end

      {i, _} ->
        <<text::binary-size(^i), tail::binary>> = rest
        scan(tail, [{:text, text} | acc])
    end
  end

  defp take_tag(rest) do
    case :binary.match(rest, ">") do
      :nomatch -> {rest, ""}
      {i, _} -> {binary_part(rest, 0, i + 1), binary_part(rest, i + 1, byte_size(rest) - i - 1)}
    end
  end

  defp take_until_close(rest, name) do
    close = "</" <> name

    case :binary.match(rest, close) do
      :nomatch ->
        {rest, ""}

      {i, _} ->
        {tag, tail} = take_tag(binary_part(rest, i, byte_size(rest) - i))
        {binary_part(rest, 0, i) <> tag, tail}
    end
  end

  defp tag_name(tag) do
    tag
    |> String.trim_leading("<")
    |> String.trim_leading("/")
    |> String.split(~r/[\s>\/]/, parts: 2)
    |> hd()
    |> String.downcase()
  end

  # ── 地の文を、左から一度だけなめる ──────────────────────────────
  #
  # `@` と `#` のどちらが先に来るかを毎回見て、近いほうを先に確定させる。
  # 二回に分けて走らせると、一度目が作ったリンクの中を二度目が読む。
  defp linkify_text(text, lookup) do
    mention = Regex.run(@mention, text, return: :index)
    hashtag = Regex.run(@hashtag, text, return: :index)

    case first_of(mention, hashtag) do
      nil ->
        text

      {:mention, [{at, len} | _] = caps} ->
        replace_at(text, at, len, mention_html(text, caps, lookup), lookup)

      {:hashtag, [{at, len} | _] = caps} ->
        replace_at(text, at, len, hashtag_html(text, caps), lookup)
    end
  end

  defp first_of(nil, nil), do: nil
  defp first_of(m, nil), do: {:mention, m}
  defp first_of(nil, h), do: {:hashtag, h}

  defp first_of([{mi, _} | _] = m, [{hi, _} | _] = h),
    do: if(mi <= hi, do: {:mention, m}, else: {:hashtag, h})

  defp replace_at(text, at, len, replacement, lookup) do
    before = binary_part(text, 0, at)
    rest = binary_part(text, at + len, byte_size(text) - at - len)
    # 置いたぶんは、もう見ない。続きだけを、また左からなめる。
    before <> replacement <> linkify_text(rest, lookup)
  end

  defp mention_html(text, caps, lookup) do
    raw = slice(text, Enum.at(caps, 0))
    user = slice(text, Enum.at(caps, 1))
    host = slice(text, Enum.at(caps, 2))
    handle = if host in [nil, ""], do: user, else: "#{user}@#{host}"

    case lookup.(handle) do
      %{url: url} when is_binary(url) ->
        ~s|<span class="h-card"><a href="#{esc(url)}" class="u-url mention">@<span>#{esc(user)}</span></a></span>|

      _ ->
        # 知らない名前。平文のまま置く ── リンクにならないのは、壊れて
        # いるのではなく、知らないだけ。
        raw
    end
  end

  defp hashtag_html(text, caps) do
    tag = slice(text, Enum.at(caps, 1))
    ~s|<a href="/tags/#{URI.encode(String.downcase(tag))}" class="mention hashtag" rel="tag">#<span>#{esc(tag)}</span></a>|
  end

  defp slice(_text, nil), do: nil
  defp slice(_text, {-1, _}), do: nil
  defp slice(text, {at, len}), do: binary_part(text, at, len)

  defp esc(s), do: Plug.HTML.html_escape(s)
end
