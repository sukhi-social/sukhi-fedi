# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.LinkifyTest do
  @moduledoc """
  `@だれか` と `#なにか` を、リンクに変えるところ。

  ここは黙って壊れる質のもの ── 出てくるのは常に「それらしい HTML」で、
  リンクの中にリンクが入っていても、コードの中の `#include` を掴んでいても、
  ぱっと見は普通に見える。だから細かく置いておく。
  """
  use ExUnit.Case, async: true

  # 純粋。DB を触らない(lookup を渡す)。runner は --only integration。
  @moduletag :integration

  alias SukhiFedi.Linkify

  # ここにいる人・知っている遠くの人・知らない人。
  defp lookup("nyanrus"), do: %{acct: "nyanrus", url: "https://sukhi.f3liz.casa/@nyanrus"}
  defp lookup("shiro_mudita"), do: %{acct: "shiro_mudita", url: "https://sukhi.f3liz.casa/@shiro_mudita"}
  defp lookup("far@example.social"), do: %{acct: "far@example.social", url: "https://example.social/@far"}
  defp lookup(_), do: nil

  defp run(html), do: Linkify.run(html, &lookup/1)

  describe "言及" do
    test "ここの人は、リンクになる" do
      out = run("<p>@nyanrus こんにちは</p>")
      assert out =~ ~s|class="h-card"|
      assert out =~ ~s|href="https://sukhi.f3liz.casa/@nyanrus"|
      assert out =~ "@<span>nyanrus</span>"
      assert out =~ "こんにちは"
    end

    test "遠くの人も、知っていればリンクになる" do
      assert run("<p>@far@example.social やあ</p>") =~ ~s|href="https://example.social/@far"|
    end

    test "**知らない名前は、平文のまま**" do
      # リンクにならないのは壊れているのではなく、知らないだけ。
      # ここで WebFinger に行くと、投稿するたび相手の選んだホストへ出る。
      out = run("<p>@nobody やあ</p>")
      assert out == "<p>@nobody やあ</p>"
    end

    test "メールアドレスの尻尾を掴まない" do
      out = run("<p>a@nyanrus.example に送った</p>")
      refute out =~ "h-card"
    end
  end

  describe "ハッシュタグ" do
    test "リンクになる" do
      out = run("<p>きょうは #散歩 した</p>")
      assert out =~ ~s|class="mention hashtag"|
      assert out =~ ~s|rel="tag"|
      assert out =~ "#<span>散歩</span>"
    end

    test "行き先は小文字にそろえる(表示はそのまま)" do
      out = run("<p>#Elixir</p>")
      assert out =~ "/tags/elixir"
      assert out =~ "#<span>Elixir</span>"
    end

    test "数字だけのタグは作らない" do
      # `#1` は番号のことが多い。GitHub の issue 番号とか。
      assert run("<p>#1 のこと</p>") == "<p>#1 のこと</p>"
    end

    test "日本語のタグも通る" do
      assert run("<p>#猫</p>") =~ "#<span>猫</span>"
    end
  end

  describe "触ってはいけないところ" do
    test "**コードの中の # は、タグではない**" do
      out = run("<p>これ <code>#include &lt;stdio.h&gt;</code> ね</p>")
      refute out =~ "hashtag"
      assert out =~ "<code>#include"
    end

    test "リンクの中には、リンクを作らない" do
      out = run(~s|<p><a href="https://x.example/@nyanrus">@nyanrus のところ</a></p>|)
      # a の中は丸ごと素通し。h-card は増えない。
      refute out =~ "h-card"
    end

    test "タグの属性の中は読まない" do
      # href の中の `#anchor` を掴むと、URL が壊れる。
      out = run(~s|<p><img src="/x.png#frag" alt="@nyanrus"></p>|)
      refute out =~ "hashtag"
      refute out =~ "h-card"
    end

    test "pre の中も、そのまま" do
      out = run("<pre>@nyanrus #tag</pre>")
      assert out == "<pre>@nyanrus #tag</pre>"
    end
  end

  describe "ひとつの走査で、両方いっしょに" do
    test "言及とタグが混ざっていても、どちらも壊れない" do
      out = run("<p>@nyanrus #散歩 いこう</p>")
      assert out =~ "h-card"
      assert out =~ "hashtag"
    end

    test "**入れたリンクの中を、読み直さない**" do
      # 二回に分けて走らせると、`#` の回が h-card の URL の中を掴む。
      # 一度で進むので、そうならない。
      out = run("<p>@nyanrus</p>")
      assert out =~ ~s|href="https://sukhi.f3liz.casa/@nyanrus"|
      # 入れた URL の中の `@nyanrus` が、二重にリンクされていないこと。
      assert length(String.split(out, "h-card")) == 2
    end

    test "順番が逆でも同じ" do
      out = run("<p>#散歩 と @nyanrus</p>")
      assert out =~ "hashtag"
      assert out =~ "h-card"
    end

    test "たくさんあっても、ぜんぶ拾う" do
      out = run("<p>@nyanrus @shiro_mudita #a #b</p>")
      assert length(String.split(out, "h-card")) == 3
      assert length(String.split(out, "hashtag")) == 3
    end
  end

  describe "壊れた入力" do
    test "空でも、閉じていないタグでも転ばない" do
      assert run("") == ""
      assert is_binary(run("<p>@nyanrus"))
      assert is_binary(run("<a href='x'>閉じてない"))
    end

    test "binary でなければ、そのまま返す" do
      assert Linkify.run(nil, &lookup/1) == nil
    end
  end

  describe "できた HTML は、allow-list を通れる" do
    test "scrubber を抜けても、リンクが残る" do
      # ここで作った小さな HTML は、必ずそのあと scrubber を通る。
      # class や href が落とされたら、見た目は無事なのに機能だけ消える。
      out = run("<p>@nyanrus #散歩</p>") |> SukhiFedi.HTML.sanitize()
      assert out =~ ~s|href="https://sukhi.f3liz.casa/@nyanrus"|
      assert out =~ "h-card"
      assert out =~ "hashtag"
      assert out =~ "/tags/"
    end
  end
end
