# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Integration.GroupMembershipTest do
  @moduledoc """
  Join / Leave a remote group (`Social.join_group/2`, `Social.leave_group/2`),
  the group's `Accept` / `Reject` coming back (`AP.Instructions.Memberships`),
  and how the Relationship shows it.
  """

  use SukhiFedi.IntegrationCase, async: false

  @moduletag :integration

  import Ecto.Query

  alias SukhiFedi.{Repo, Social}
  alias SukhiFedi.AP.Instructions.{Follows, Memberships}
  alias SukhiFedi.Schema.{Account, Follow, GroupMembership, OutboxEvent}

  @group_uri "https://bonfire.test/pub/group/libs"

  describe "join_group/2" do
    test "stores a pending membership, follows the group, and enqueues the Join" do
      alice = account!("alice_jg")
      group = remote_group!("libs_jg")

      {:ok, m} = Social.join_group(alice, group.id)

      assert m.state == "pending"
      assert m.member_uri == local_uri("alice_jg")
      assert m.group_id == group.id

      # joining follows — Boosts only materialise from followed actors
      assert [%Follow{follower_uri: follower}] = follows_of(group.id)
      assert follower == local_uri("alice_jg")

      ev = event("sns.outbox.join.requested", m.id)
      assert ev.payload["membership_id"] == m.id
      assert ev.payload["member_uri"] == m.member_uri
      assert ev.payload["group_id"] == group.id
    end

    test "is idempotent — a second join returns the same row and enqueues nothing more" do
      alice = account!("alice_jg2")
      group = remote_group!("libs_jg2")

      {:ok, m1} = Social.join_group(alice, group.id)
      {:ok, m2} = Social.join_group(alice, group.id)

      assert m1.id == m2.id
      assert count_events("sns.outbox.join.requested", m1.id) == 1
    end

    test "a local account has no Join to send" do
      alice = account!("alice_jg3")
      bob = account!("bob_jg3")

      assert {:error, :not_remote} = Social.join_group(alice, bob.id)
      assert Repo.all(GroupMembership) |> Enum.filter(&(&1.member_uri == local_uri("alice_jg3"))) == []
    end

    test "an unknown group is :not_found" do
      alice = account!("alice_jg4")
      assert {:error, :not_found} = Social.join_group(alice, 99_999_999)
    end
  end

  describe "leave_group/2" do
    test "deletes the membership, enqueues the Leave, and keeps the follow" do
      alice = account!("alice_lg")
      group = remote_group!("libs_lg")
      {:ok, m} = Social.join_group(alice, group.id)

      assert {:ok, _} = Social.leave_group(alice, group.id)

      assert Repo.get(GroupMembership, m.id) == nil
      assert event("sns.outbox.join.undone", m.id).payload["group_id"] == group.id
      # leaving and unfollowing are two choices
      assert [%Follow{}] = follows_of(group.id)
    end

    test "without a membership there is nothing to leave" do
      alice = account!("alice_lg2")
      group = remote_group!("libs_lg2")

      assert {:error, :not_found} = Social.leave_group(alice, group.id)
    end
  end

  describe "the group's answer" do
    test "Accept with the Join embedded makes the member accepted" do
      {alice, group, m} = joined!("alice_ac", "libs_ac")

      reply(%{
        "type" => "Accept",
        "actor" => group.actor_uri,
        "object" => %{
          "type" => "Join",
          "actor" => local_uri(alice.username),
          "object" => group.actor_uri
        }
      })

      assert Repo.get!(GroupMembership, m.id).state == "accepted"
    end

    test "Accept naming the Join by the id we gave it makes the member accepted" do
      {_alice, group, m} = joined!("alice_ac2", "libs_ac2")

      reply(%{"type" => "Accept", "actor" => group.actor_uri, "object" => join_id(m)})

      assert Repo.get!(GroupMembership, m.id).state == "accepted"
    end

    test "Reject removes the membership" do
      {_alice, group, m} = joined!("alice_rj", "libs_rj")

      reply(%{"type" => "Reject", "actor" => group.actor_uri, "object" => join_id(m)})

      assert Repo.get(GroupMembership, m.id) == nil
    end

    test "someone other than the group can't answer for it" do
      {alice, group, m} = joined!("alice_imp", "libs_imp")
      other = remote_group!("other_imp", "elsewhere.test")

      reply(%{"type" => "Accept", "actor" => other.actor_uri, "object" => join_id(m)})

      reply(%{
        "type" => "Accept",
        "actor" => other.actor_uri,
        "object" => %{
          "type" => "Join",
          "actor" => local_uri(alice.username),
          "object" => group.actor_uri
        }
      })

      reply(%{"type" => "Reject", "actor" => other.actor_uri, "object" => join_id(m)})

      assert Repo.get!(GroupMembership, m.id).state == "pending"
    end

    test "an id that isn't one of our joins is ignored" do
      {_alice, group, m} = joined!("alice_junk", "libs_junk")

      reply(%{"type" => "Accept", "actor" => group.actor_uri, "object" => "https://elsewhere.test/joins/#{m.id}"})
      reply(%{"type" => "Accept", "actor" => group.actor_uri, "object" => "https://#{SukhiFedi.Config.domain!()}/joins/abc"})

      assert Repo.get!(GroupMembership, m.id).state == "pending"
    end
  end

  describe "Accept(Follow) naming our Follow by id" do
    test "the followee's Accept settles the follow" do
      alice = account!("alice_af")
      group = remote_group!("libs_af")
      {:ok, follow} = Social.request_follow(alice, group.id)

      manual(fn ->
        Follows.maybe_handle_follow_accept(%{
          "type" => "Accept",
          "actor" => group.actor_uri,
          "object" => "https://#{SukhiFedi.Config.domain!()}/follows/#{follow.id}"
        })
      end)

      assert Repo.get!(Follow, follow.id).state == "accepted"
    end

    test "an Accept from anyone but the followee leaves it pending" do
      alice = account!("alice_af2")
      group = remote_group!("libs_af2")
      other = remote_group!("other_af2", "elsewhere.test")
      {:ok, follow} = Social.request_follow(alice, group.id)

      manual(fn ->
        Follows.maybe_handle_follow_accept(%{
          "type" => "Accept",
          "actor" => other.actor_uri,
          "object" => "https://#{SukhiFedi.Config.domain!()}/follows/#{follow.id}"
        })
      end)

      assert Repo.get!(Follow, follow.id).state == "pending"
    end
  end

  describe "list_relationships/2" do
    test "group is absent without a membership, pending → not yet a member, accepted → member" do
      alice = account!("alice_rel")
      group = remote_group!("libs_rel")

      [none] = Social.list_relationships(alice, [group.id])
      assert none.group == nil
      refute none.requested

      {:ok, m} = Social.join_group(alice, group.id)
      [pending] = Social.list_relationships(alice, [group.id])
      assert pending.requested
      assert pending.group == %{member: false, role: nil}

      reply(%{"type" => "Accept", "actor" => group.actor_uri, "object" => join_id(m)})
      [accepted] = Social.list_relationships(alice, [group.id])
      assert accepted.group == %{member: true, role: "member"}
    end
  end

  # ── helpers ────────────────────────────────────────────────────────────

  defp joined!(username, group_name) do
    alice = account!(username)
    group = remote_group!(group_name)
    {:ok, m} = Social.join_group(alice, group.id)
    {alice, group, m}
  end

  # The inbox hands an Accept/Reject to this one function.
  defp reply(activity), do: Memberships.maybe_handle_join_reply(activity)

  defp join_id(%GroupMembership{id: id}), do: "https://#{SukhiFedi.Config.domain!()}/joins/#{id}"

  defp follows_of(followee_id), do: Repo.all(from f in Follow, where: f.followee_id == ^followee_id)

  defp event(subject, membership_id) do
    SukhiFedi.AccountRepo.one!(
      from e in OutboxEvent,
        where: e.subject == ^subject and e.aggregate_id == ^to_string(membership_id)
    )
  end

  defp count_events(subject, membership_id) do
    SukhiFedi.AccountRepo.aggregate(
      from(e in OutboxEvent, where: e.subject == ^subject and e.aggregate_id == ^to_string(membership_id)),
      :count,
      :id
    )
  end

  # Accept(Follow) enqueues an Oban job; the delivery worker lives on another
  # node and isn't loaded in the gateway test VM.
  defp manual(fun), do: Oban.Testing.with_testing_mode(:manual, fun)

  defp local_uri(username), do: "https://#{SukhiFedi.Config.domain!()}/users/#{username}"

  defp account!(username) do
    %Account{username: username, display_name: username, summary: ""}
    |> insert_account!()
  end

  defp remote_group!(username, domain \\ "bonfire.test") do
    %Account{
      username: username,
      display_name: username,
      summary: "",
      domain: domain,
      actor_uri: if(domain == "bonfire.test", do: "#{@group_uri}-#{username}", else: "https://#{domain}/users/#{username}"),
      inbox_url: "https://#{domain}/inbox"
    }
    |> insert_account!()
  end
end
