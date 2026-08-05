# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.VisibilityTest do
  @moduledoc """
  「どこまで見せるか」の一覧。

  この一覧は八箇所に手で書かれていて、二種類あるのに見た目がほとんど
  同じだった。そして**書き忘れても何も起きない** ── クエリは通るし、
  行も返る。返ってはいけないものが混ざるだけ。

  実際そうなって、プロフィールの投稿数に DM が入っていた。
  ここは、その一覧が静かに変わらないための杭。
  """
  use ExUnit.Case, async: true

  @moduletag :integration

  alias SukhiFedi.Visibility

  test "not_direct は、DM だけを外す" do
    assert Visibility.not_direct() == ["public", "unlisted", "followers"]
    refute "direct" in Visibility.not_direct()
  end

  test "public_only は、ログインしていない人に出せるものだけ" do
    assert Visibility.public_only() == ["public", "unlisted"]
    refute "followers" in Visibility.public_only()
    refute "direct" in Visibility.public_only()
  end

  test "**unlisted は公開のうち**" do
    # 「一覧に載せない」であって「見せない」ではない。ここを外すと、
    # 未ログインの人に見えるはずの投稿が消える。
    assert "unlisted" in Visibility.public_only()
  end

  test "public_only は not_direct の一部" do
    # 狭いほうが広いほうにちゃんと含まれている。
    assert Enum.all?(Visibility.public_only(), &(&1 in Visibility.not_direct()))
  end

  test "all は、この鯖が受け付けるぜんぶ" do
    # Note の changeset が validate_inclusion で使う値と揃っていること。
    assert Enum.sort(Visibility.all()) == Enum.sort(["public", "unlisted", "followers", "direct"])
    assert Enum.all?(Visibility.not_direct(), &(&1 in Visibility.all()))
  end

  test "direct? は手紙だけに true" do
    assert Visibility.direct?("direct")
    for v <- Visibility.not_direct(), do: refute(Visibility.direct?(v))
    refute Visibility.direct?(nil)
  end
end
