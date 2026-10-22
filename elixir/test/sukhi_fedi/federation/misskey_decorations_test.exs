# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Federation.MisskeyDecorationsTest do
  @moduledoc "users/show の読み方と、保存前の門(Account.changeset_decorations)。"

  use ExUnit.Case, async: true

  alias SukhiFedi.Federation.{MisskeyDecorations, RemoteAccounts}
  alias SukhiFedi.Schema.Account

  test "parse reads Misskey's camelCase keys and skips rows without a url" do
    body = %{
      "avatarDecorations" => [
        %{"id" => "a", "url" => "https://m.test/d.png", "angle" => 0.1, "flipH" => true, "offsetX" => 0.2, "offsetY" => -0.1},
        %{"id" => "b"}
      ]
    }

    assert [%{"url" => "https://m.test/d.png", "angle" => 0.1, "flip_h" => true, "offset_x" => 0.2, "offset_y" => -0.1}] =
             MisskeyDecorations.parse(body)
  end

  test "parse accepts the shape misskey.kyu.sh really sends (angle/flipH omitted when default)" do
    body = %{
      "avatarDecorations" => [
        %{"id" => "anum7ex39pq7008z", "offsetX" => -0.075, "offsetY" => 0.075, "url" => "https://misskey.kyu.sh/files/2599e6b6"}
      ]
    }

    [row] = MisskeyDecorations.parse(body)
    [clean] = Ecto.Changeset.get_change(Account.changeset_decorations(%Account{}, [row]), :avatar_decorations) |> List.wrap()

    assert %{"angle" => +0.0, "flip_h" => false, "offset_x" => -0.075, "offset_y" => 0.075} = clean
  end

  test "parse is empty for a body without decorations" do
    assert [] = MisskeyDecorations.parse(%{"id" => "x"})
    assert [] = MisskeyDecorations.parse("not json")
  end

  test "the changeset keeps http(s) urls, clamps numbers, caps at four" do
    rows =
      [%{"url" => "javascript:alert(1)"}, %{"url" => "https://m.test/a.png", "angle" => 9, "offset_x" => "x"}] ++
        for i <- 1..5, do: %{"url" => "https://m.test/#{i}.png"}

    cs = Account.changeset_decorations(%Account{}, rows)
    got = Ecto.Changeset.get_change(cs, :avatar_decorations)

    assert length(got) == 4
    assert [%{"url" => "https://m.test/a.png", "angle" => 0.5, "offset_x" => 0.0} | _] = got
  end

  test "only actors declaring the misskey namespace are asked" do
    assert RemoteAccounts.misskey_family?(%{"@context" => ["https://www.w3.org/ns/activitystreams", %{"misskey" => "https://misskey-hub.net/ns#"}]})
    refute RemoteAccounts.misskey_family?(%{"@context" => ["https://www.w3.org/ns/activitystreams"]})
    refute RemoteAccounts.misskey_family?(%{})
  end
end
