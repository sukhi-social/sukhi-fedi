# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Integration.FeedbackTest do
  use SukhiFedi.IntegrationCase, async: false

  @moduletag :integration

  alias SukhiFedi.Feedback
  alias SukhiFedi.Schema.Account

  defp create_account!(username) do
    %Account{username: username, display_name: username, summary: ""} |> Repo.insert!()
  end

  defp errors_on(%Ecto.Changeset{} = cs) do
    Ecto.Changeset.traverse_errors(cs, fn {msg, _opts} -> msg end)
  end

  describe "submit/2" do
    test "stores a trimmed body; anonymous has no account" do
      {:ok, item} =
        Feedback.submit(%{"body" => "  it crashed  ", "screen" => "timeline", "lang" => "ja", "version" => "1.0"}, nil)

      assert item.body == "it crashed"
      assert item.account_id == nil
      assert item.screen == "timeline"
    end

    test "records the account id when given; never takes it from the attrs" do
      sender = create_account!("fb_sender")
      other = create_account!("fb_other")

      {:ok, item} = Feedback.submit(%{"body" => "hi", "account_id" => other.id}, sender.id)
      assert item.account_id == sender.id
    end

    test "body must be 1..2000 characters after trimming" do
      assert {:error, cs} = Feedback.submit(%{"body" => "   "}, nil)
      assert %{body: [_ | _]} = errors_on(cs)

      assert {:error, _} = Feedback.submit(%{}, nil)
      assert {:error, cs} = Feedback.submit(%{"body" => String.duplicate("a", 2001)}, nil)
      assert %{body: [_ | _]} = errors_on(cs)

      assert {:ok, _} = Feedback.submit(%{"body" => String.duplicate("a", 2000)}, nil)
    end

    test "screen / lang / version have their caps" do
      assert {:error, cs} =
               Feedback.submit(
                 %{
                   "body" => "x",
                   "screen" => String.duplicate("s", 65),
                   "lang" => String.duplicate("l", 17),
                   "version" => String.duplicate("v", 65)
                 },
                 nil
               )

      assert %{screen: _, lang: _, version: _} = errors_on(cs)
    end

    test "a non-string body is invalid, not a crash" do
      assert {:error, _} = Feedback.submit(%{"body" => 12}, nil)
    end
  end

  describe "list/2, mark_handled/2, purge" do
    test "newest first, filterable by handled, with a total" do
      admin = create_account!("fb_admin")
      {:ok, a} = Feedback.submit(%{"body" => "one"}, nil)
      {:ok, b} = Feedback.submit(%{"body" => "two"}, nil)

      assert {[%{id: id1}, %{id: id2}], 2} = Feedback.list(%{offset: 0, limit: 10})
      assert [id1, id2] == [b.id, a.id]

      {:ok, done} = Feedback.mark_handled(Integer.to_string(a.id), admin.id)
      assert done.handled_by_id == admin.id
      assert %DateTime{} = done.handled_at

      assert {[%{id: only}], 1} = Feedback.list(%{offset: 0, limit: 10}, false)
      assert only == b.id
      assert {[%{id: handled}], 1} = Feedback.list(%{offset: 0, limit: 10}, true)
      assert handled == a.id

      assert {[_], 2} = Feedback.list(%{offset: 1, limit: 1})
    end

    test "mark_handled is idempotent and 404s on junk" do
      admin = create_account!("fb_admin2")
      {:ok, a} = Feedback.submit(%{"body" => "one"}, nil)
      {:ok, first} = Feedback.mark_handled(a.id, admin.id)
      {:ok, second} = Feedback.mark_handled(a.id, admin.id)
      assert first.handled_at == second.handled_at

      assert {:error, :not_found} = Feedback.mark_handled("nope", admin.id)
      assert {:error, :not_found} = Feedback.mark_handled(0, admin.id)
    end

    test "purge removes only old handled items" do
      admin = create_account!("fb_admin3")
      {:ok, handled} = Feedback.submit(%{"body" => "done"}, nil)
      {:ok, open} = Feedback.submit(%{"body" => "open"}, nil)
      {:ok, _} = Feedback.mark_handled(handled.id, admin.id)

      assert 0 == Feedback.purge_handled_before(DateTime.add(DateTime.utc_now(), -3600))
      assert 1 == Feedback.purge_handled_before(DateTime.add(DateTime.utc_now(), 3600))
      assert {[%{id: id}], 1} = Feedback.list(%{offset: 0, limit: 10})
      assert id == open.id
    end

    test "deleting the sender's account keeps the item, detached" do
      sender = create_account!("fb_gone")
      {:ok, item} = Feedback.submit(%{"body" => "bye"}, sender.id)
      Repo.delete!(sender)
      assert %{account_id: nil} = Repo.get!(SukhiFedi.Schema.FeedbackItem, item.id)
    end
  end
end
