# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Integration.ListsTest do
  use SukhiFedi.IntegrationCase, async: false

  @moduletag :integration

  alias SukhiFedi.{Lists, Notes, Social}
  alias SukhiFedi.Schema.Account

  describe "create/3 + list_for/1" do
    test "owner-scoped — alice's lists don't show in bob's index" do
      alice = create_account!("alice_lists")
      bob = create_account!("bob_lists")

      {:ok, list} = Lists.create(alice.id, %{title: "Friends"})
      assert list.title == "Friends"

      assert [%{id: lid, title: "Friends"}] = Lists.list_for(alice.id)
      assert lid == list.id
      assert Lists.list_for(bob.id) == []
    end
  end

  describe "membership" do
    test "adds any existing account regardless of follow; skips non-existent ids" do
      alice = create_account!("alice_mem")
      bob = create_account!("bob_mem")
      carol = create_account!("carol_mem")

      # alice follows bob but NOT carol
      {:ok, _} = Social.request_follow(alice, bob.id)
      {:ok, list} = Lists.create(alice.id, %{title: "Inner circle"})

      # A circle is a roster, not a subscription: both the followed (bob) and
      # the un-followed (carol) go in. The non-existent id is skipped (FK).
      assert :ok = Lists.add_accounts(alice.id, list.id, [bob.id, carol.id, 99_999_999])
      assert {:ok, members} = Lists.list_accounts(alice.id, list.id)
      ids = members |> Enum.map(& &1.id) |> Enum.sort()
      assert ids == Enum.sort([bob.id, carol.id])

      # adding to a circle never changes who alice follows: carol stays unfollowed
      [rel] = Social.list_relationships(alice, [carol.id])
      refute rel.following
    end

    test "remove_accounts is idempotent" do
      alice = create_account!("alice_rm")
      bob = create_account!("bob_rm")
      {:ok, _} = Social.request_follow(alice, bob.id)
      {:ok, list} = Lists.create(alice.id, %{title: "x"})
      :ok = Lists.add_accounts(alice.id, list.id, [bob.id])

      assert :ok = Lists.remove_accounts(alice.id, list.id, [bob.id])
      assert :ok = Lists.remove_accounts(alice.id, list.id, [bob.id])
      assert {:ok, []} = Lists.list_accounts(alice.id, list.id)
    end
  end

  describe "excluded_account_ids/1" do
    test "returns members of exclusive lists only, never the viewer" do
      alice = create_account!("alice_excl")
      bob = create_account!("bob_excl")
      carol = create_account!("carol_excl")

      {:ok, circle} = Lists.create(alice.id, %{title: "circle", exclusive: true})
      {:ok, plain} = Lists.create(alice.id, %{title: "plain", exclusive: false})

      :ok = Lists.add_accounts(alice.id, circle.id, [bob.id])
      :ok = Lists.add_accounts(alice.id, plain.id, [carol.id])

      excluded = Lists.excluded_account_ids(alice.id)

      # bob is in an exclusive circle → kept out of home
      assert bob.id in excluded
      # carol is only in a plain list → still shown in home
      refute carol.id in excluded
      # the viewer is never excluded from their own home
      refute alice.id in excluded
    end
  end

  describe "timeline" do
    test "returns notes from list members only" do
      alice = create_account!("alice_tl_l")
      bob = create_account!("bob_tl_l")
      carol = create_account!("carol_tl_l")

      {:ok, _} = Social.request_follow(alice, bob.id)
      {:ok, list} = Lists.create(alice.id, %{title: "from-bob"})
      :ok = Lists.add_accounts(alice.id, list.id, [bob.id])

      # only bob's note should appear
      {:ok, _} = Notes.create_status(bob, %{"status" => "from bob"})
      {:ok, _} = Notes.create_status(carol, %{"status" => "from carol"})

      {:ok, notes} = Lists.timeline(alice.id, list.id)

      assert length(notes) == 1
      [%{account_id: aid}] = notes
      assert aid == bob.id
    end

    test "scope mismatch — viewer doesn't own the list → :not_found" do
      alice = create_account!("alice_scope")
      bob = create_account!("bob_scope")
      {:ok, list} = Lists.create(alice.id, %{title: "private"})

      assert {:error, :not_found} = Lists.timeline(bob.id, list.id)
      assert {:error, :not_found} = Lists.list_accounts(bob.id, list.id)
    end
  end

  defp create_account!(username) do
    %Account{username: username, display_name: username, summary: ""}
    |> insert_account!()
  end
end
