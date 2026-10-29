# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Integration.NotificationsTest do
  @moduledoc """
  Exercises `SukhiFedi.Notifications` + the local-to-local write paths
  in `SukhiFedi.Notes` / `SukhiFedi.Social` that should emit rows.

      docker compose -f docker-compose.test.yml up -d
      MIX_ENV=test mix ecto.migrate
      mix test --only integration
  """

  use SukhiFedi.IntegrationCase, async: false

  @moduletag :integration

  import Ecto.Query

  alias SukhiFedi.{Notes, Notifications, Social}
  alias SukhiFedi.Schema.{Account, Note}

  describe "Social.request_follow/2 (local target)" do
    test "emits a `follow` notification for the followee" do
      alice = create_account!("alice_n_f")
      bob = create_account!("bob_n_f")

      {:ok, _} = Social.request_follow(alice, bob.id)

      [n] = Notifications.list(bob.id, [])
      assert n.type == "follow"
      assert n.from_account_id == alice.id
    end

    test "self-follow does not generate a notification (and is rejected)" do
      alice = create_account!("alice_self_n")
      assert {:error, :self_follow} = Social.request_follow(alice, alice.id)
      assert Notifications.list(alice.id, []) == []
    end
  end

  describe "Notes.favourite/2" do
    test "emits a `favourite` notification for the note author" do
      alice = create_account!("alice_fav")
      bob = create_account!("bob_fav")
      note = create_note!(alice.id, "hello")

      {:ok, _} = Notes.favourite(bob, note.id)

      [n] = Notifications.list(alice.id, [])
      assert n.type == "favourite"
      assert n.from_account_id == bob.id
      assert n.note_id == note.id
    end

    test "self-favourite does NOT notify (account_id == from_account_id)" do
      alice = create_account!("alice_selffav")
      note = create_note!(alice.id, "mine")
      {:ok, _} = Notes.favourite(alice, note.id)
      assert Notifications.list(alice.id, []) == []
    end
  end

  describe "Notes.reblog/2" do
    test "emits a `reblog` notification for the note author" do
      alice = create_account!("alice_reb")
      bob = create_account!("bob_reb")
      note = create_note!(alice.id, "boost me")

      {:ok, _} = Notes.reblog(bob, note.id)

      [n] = Notifications.list(alice.id, [])
      assert n.type == "reblog"
      assert n.from_account_id == bob.id
    end
  end

  describe "Notifications.list/2 filters" do
    test "types[] keeps only matching, exclude_types[] drops" do
      alice = create_account!("alice_filt")
      bob = create_account!("bob_filt")
      carol = create_account!("carol_filt")

      {:ok, _} = Social.request_follow(bob, alice.id)
      note = create_note!(alice.id, "x")
      {:ok, _} = Notes.favourite(carol, note.id)

      assert [%{type: "favourite"}] =
               Notifications.list(alice.id, types: ["favourite"])

      assert [%{type: "follow"}] =
               Notifications.list(alice.id, exclude_types: ["favourite"])

      assert length(Notifications.list(alice.id, [])) == 2
    end
  end

  describe "Notifications.dismiss/2 + clear/1" do
    test "dismiss flips dismissed_at; cleared rows disappear from list" do
      alice = create_account!("alice_dis")
      bob = create_account!("bob_dis")
      {:ok, _} = Social.request_follow(bob, alice.id)

      [n] = Notifications.list(alice.id, [])
      assert :ok = Notifications.dismiss(alice.id, n.id)
      assert Notifications.list(alice.id, []) == []
    end

    test "clear/1 bulk-dismisses every row" do
      alice = create_account!("alice_clr")
      bob = create_account!("bob_clr")
      carol = create_account!("carol_clr")

      {:ok, _} = Social.request_follow(bob, alice.id)
      {:ok, _} = Social.request_follow(carol, alice.id)
      assert length(Notifications.list(alice.id, [])) == 2

      assert :ok = Notifications.clear(alice.id)
      assert Notifications.list(alice.id, []) == []
    end
  end

  describe "pace: hold and grouping of ambient notifications" do
    setup do
      alice = create_account!("alice_pace")
      bob = create_account!("bob_pace")
      carol = create_account!("carol_pace")
      note = create_note!(alice.id, "hello")
      %{alice: alice, bob: bob, carol: carol, note: note}
    end

    defp set_pace!(account, hold, grouping \\ false) do
      {:ok, _} =
        SukhiFedi.Accounts.update_credentials(account.id, %{
          "notification_hold_minutes" => hold,
          "notification_grouping" => grouping
        })
    end

    # Make a row look `minutes` old.
    defp age!(notification, minutes) do
      at = DateTime.utc_now() |> DateTime.add(-minutes * 60, :second) |> DateTime.truncate(:second)

      Repo.update_all(
        from(n in SukhiFedi.Schema.Notification, where: n.id == ^notification.id),
        set: [created_at: at]
      )
    end

    test "nothing is held until the account chooses", %{alice: alice, bob: bob, note: note} do
      {:ok, _} = Notes.favourite(bob, note.id)
      assert [%{type: "favourite"}] = Notifications.list(alice.id, [])
      assert %{hold_minutes: 0, grouping: false} = Notifications.pace(alice.id)
    end

    test "a held favourite shows once its time is up; a mention never waits",
         %{alice: alice, bob: bob, carol: carol, note: note} do
      set_pace!(alice, 60)
      {:ok, _} = Notes.favourite(bob, note.id)
      {:ok, _} = Social.request_follow(carol, alice.id)

      {:ok, _} =
        Notifications.create(%{
          account_id: alice.id,
          from_account_id: bob.id,
          type: "mention",
          note_id: note.id
        })

      types = alice.id |> Notifications.list([]) |> Enum.map(& &1.type)
      assert types == ["mention"]

      [fav] = Repo.all(from(n in SukhiFedi.Schema.Notification, where: n.type == "favourite"))
      age!(fav, 61)
      assert "favourite" in (alice.id |> Notifications.list([]) |> Enum.map(& &1.type))
    end

    test "a held row cannot be fetched, dismissed or cleared yet",
         %{alice: alice, bob: bob, note: note} do
      set_pace!(alice, 60)
      {:ok, _} = Notes.favourite(bob, note.id)
      [fav] = Repo.all(from(n in SukhiFedi.Schema.Notification, where: n.type == "favourite"))

      assert Notifications.get(alice.id, fav.id) == nil
      assert :ok = Notifications.dismiss(alice.id, fav.id)
      assert :ok = Notifications.clear(alice.id)

      age!(fav, 61)
      assert %{type: "favourite"} = Notifications.get(alice.id, fav.id)
      assert [%{type: "favourite"}] = Notifications.list(alice.id, [])
    end

    test "grouping folds ambient rows of one kind and leaves the rest",
         %{alice: alice, bob: bob, carol: carol, note: note} do
      set_pace!(alice, 0, true)
      {:ok, _} = Notes.favourite(bob, note.id)
      {:ok, _} = Notes.favourite(carol, note.id)
      {:ok, _} = Social.request_follow(bob, alice.id)

      rows = Notifications.list(alice.id, [])
      assert Enum.sort(Enum.map(rows, & &1.type)) == ["favourite", "follow"]

      fav = Enum.find(rows, &(&1.type == "favourite"))
      assert length(fav.group) == 2
      assert fav.cursor_id < fav.id
      assert Enum.find(rows, &(&1.type == "follow")).group == nil
    end

    test "a client can ask for a slower pace than the account chose, never a faster one",
         %{alice: alice, bob: bob, note: note} do
      {:ok, _} = Notes.favourite(bob, note.id)
      [fav] = Repo.all(from(n in SukhiFedi.Schema.Notification, where: n.type == "favourite"))

      # account chose nothing; the client asks for an hour
      assert Notifications.list(alice.id, hold_minutes: 60) == []
      assert Notifications.get(alice.id, fav.id, hold_minutes: 60) == nil
      assert [%{type: "favourite"}] = Notifications.list(alice.id, [])

      # account chose an hour; a client asking for none does not undo it
      set_pace!(alice, 60)
      assert Notifications.list(alice.id, hold_minutes: 0) == []
      age!(fav, 61)
      assert [%{type: "favourite"}] = Notifications.list(alice.id, hold_minutes: 30)
    end

    test "a client can ask for grouping", %{alice: alice, bob: bob, carol: carol, note: note} do
      {:ok, _} = Notes.favourite(bob, note.id)
      {:ok, _} = Notes.favourite(carol, note.id)
      assert [%{group: [_, _]}] = Notifications.list(alice.id, grouping: true)
    end

    test "grouping off keeps every row", %{alice: alice, bob: bob, carol: carol, note: note} do
      {:ok, _} = Notes.favourite(bob, note.id)
      {:ok, _} = Notes.favourite(carol, note.id)
      assert length(Notifications.list(alice.id, [])) == 2
    end

    test "changing only the pace sends peers no actor Update", %{alice: alice} do
      before = Repo.aggregate(SukhiFedi.Schema.OutboxEvent, :count)
      set_pace!(alice, 30, true)
      assert Repo.aggregate(SukhiFedi.Schema.OutboxEvent, :count) == before
      assert %{hold_minutes: 30, grouping: true} = Notifications.pace(alice.id)
    end

    test "out-of-range hold is refused", %{alice: alice} do
      assert {:error, {:validation, _}} =
               SukhiFedi.Accounts.update_credentials(alice.id, %{"notification_hold_minutes" => 5000})
    end
  end

  defp create_account!(username) do
    %Account{username: username, display_name: username, summary: ""}
    |> Repo.insert!()
  end

  defp create_note!(account_id, content) do
    %Note{
      account_id: account_id,
      content: content,
      visibility: "public"
    }
    |> Repo.insert!()
  end
end
