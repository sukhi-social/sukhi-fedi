# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Linkify.Scanner.Elixir do
  @moduledoc """
  The scanner that runs today: `:binary.match` to walk the tags and two
  regexes for the candidates. The behaviour (and the rules it keeps) is
  `SukhiFedi.Linkify.Scanner`.
  """

  @behaviour SukhiFedi.Linkify.Scanner

  # `@user` / `@user@host`。直前が語なら掴まない(メールの尻尾を避ける)。
  @mention ~r/(?<![\w\/])@([\w]+)(?:@([\w.\-]+))?/u
  # `#tag`。**数字だけのタグは作らない** ── `#1` `#42` は番号のことが多く
  # (issue、部屋、順位)、それをタグにすると、書いた人の意図しない場所へ
  # 連れていく。だから、どこかに文字が要る。
  @hashtag ~r/(?<![\w\/&])#(?=[\p{L}\p{N}_-]*[\p{L}_])([\p{L}\p{N}_][\p{L}\p{N}_\-]*)/u

  @impl true
  def scan(html) when is_binary(html) do
    html
    |> split_by_tags()
    |> Enum.flat_map(fn
      {:tag, raw} -> [{:raw, raw}]
      {:skip, raw} -> [{:raw, raw}]
      {:text, raw} -> scan_text(raw)
    end)
  end

  # HTML を「タグ」「触らない範囲」「地の文」に切り分ける。
  #
  # 素朴だけれど、ここに来るのは Earmark が組んだ HTML だけで、人の書いた
  # ものではない ── そのあと必ず scrubber も通る。完全な parser を持つ
  # 理由がない。
  defp split_by_tags(html), do: walk(html, [])

  defp walk("", acc), do: Enum.reverse(acc)

  defp walk(rest, acc) do
    case :binary.match(rest, "<") do
      :nomatch ->
        Enum.reverse([{:text, rest} | acc])

      {0, _} ->
        {tag, after_tag} = take_tag(rest)
        name = tag_name(tag)

        if name in ~w(a code pre) and not String.starts_with?(tag, "</") do
          # この要素は、閉じるまで丸ごと触らない。
          {inner, tail} = take_until_close(after_tag, name)
          walk(tail, [{:skip, tag <> inner} | acc])
        else
          walk(after_tag, [{:tag, tag} | acc])
        end

      {i, _} ->
        <<text::binary-size(^i), tail::binary>> = rest
        walk(tail, [{:text, text} | acc])
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
  defp scan_text(""), do: []

  defp scan_text(text) do
    mention = Regex.run(@mention, text, return: :index)
    hashtag = Regex.run(@hashtag, text, return: :index)

    case first_of(mention, hashtag) do
      nil ->
        [{:raw, text}]

      {:mention, [{at, len} | _] = caps} ->
        user = slice(text, Enum.at(caps, 1))
        host = slice(text, Enum.at(caps, 2))
        found({:mention, slice(text, {at, len}), user, if(host in [nil, ""], do: nil, else: host)}, text, at, len)

      {:hashtag, [{at, len} | _] = caps} ->
        found({:hashtag, slice(text, {at, len}), slice(text, Enum.at(caps, 1))}, text, at, len)
    end
  end

  defp first_of(nil, nil), do: nil
  defp first_of(m, nil), do: {:mention, m}
  defp first_of(nil, h), do: {:hashtag, h}

  defp first_of([{mi, _} | _] = m, [{hi, _} | _] = h),
    do: if(mi <= hi, do: {:mention, m}, else: {:hashtag, h})

  # 見つけたぶんは、もう見ない。続きだけを、また左からなめる。
  defp found(token, text, at, len) do
    before = binary_part(text, 0, at)
    rest = binary_part(text, at + len, byte_size(text) - at - len)
    leading = if before == "", do: [], else: [{:raw, before}]
    leading ++ [token | scan_text(rest)]
  end

  # `Regex.run(..., return: :index)` says where a capture is; -1 means the
  # optional group did not take part.
  defp slice(_text, nil), do: nil
  defp slice(_text, {-1, _}), do: nil
  defp slice(text, {at, len}), do: binary_part(text, at, len)
end
