# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Federation.OutboxBackfillTest do
  @moduledoc """
  outbox backfill が「何を取り込むか」の入口。取り込みそのものは
  `Mirror`（DB + 相手の fetch）なので、ここでは選別だけを見る。
  """

  use ExUnit.Case, async: true

  alias SukhiFedi.Federation.OutboxBackfill

  @public "https://www.w3.org/ns/activitystreams#Public"

  defp create(visibility) do
    to =
      case visibility do
        :public -> [@public]
        :unlisted -> ["https://example.test/users/a/followers"]
        :followers -> ["https://example.test/users/a/followers"]
        :direct -> ["https://example.test/users/b"]
      end

    cc =
      case visibility do
        :public -> ["https://example.test/users/a/followers"]
        :unlisted -> [@public]
        _ -> []
      end

    %{
      "type" => "Create",
      "actor" => "https://example.test/users/a",
      "object" => %{
        "type" => "Note",
        "id" => "https://example.test/notes/1",
        "to" => to,
        "cc" => cc
      }
    }
  end

  test "公開・unlisted・followers-only の Create(Note) を取り込む" do
    assert OutboxBackfill.mirrorable?(create(:public))
    assert OutboxBackfill.mirrorable?(create(:unlisted))
    # こちらから follow している相手のフォロワー向けは、フォローして
    # いる人が見られない理由が無い。見せる範囲は visibility が保つ。
    assert OutboxBackfill.mirrorable?(create(:followers))
  end

  test "direct（本当の DM）は取り込まない" do
    refute OutboxBackfill.mirrorable?(create(:direct))
  end

  test "Article / Question も Create なら取り込む" do
    for type <- ["Article", "Question"] do
      assert OutboxBackfill.mirrorable?(put_in(create(:public), ["object", "type"], type))
    end
  end

  test "Announce（相手のブースト）や他の型は取り込まない" do
    refute OutboxBackfill.mirrorable?(%{"type" => "Announce", "object" => %{"type" => "Note"}})
    refute OutboxBackfill.mirrorable?(%{"type" => "Create", "object" => %{"type" => "Video"}})
    refute OutboxBackfill.mirrorable?(%{"type" => "Delete"})
    refute OutboxBackfill.mirrorable?(nil)
  end
end
