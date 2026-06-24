# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Integration.FollowRequestsTest do
  use SukhiFedi.IntegrationCase, async: false

  @moduletag :integration

  import Ecto.Query

  alias SukhiFedi.AP.ActorJson
  alias SukhiFedi.AP.Instructions.Follows
  alias SukhiFedi.FollowInvites
  alias SukhiFedi.Repo
  alias SukhiFedi.Schema.{Account, Follow, FollowRequest}

  describe "inbound follow to a locked account" do
    test "waits as a request instead of becoming an accepted follow" do
      alice = locked_account!("alice_fr")
      _bob = remote_follower!("bob_fr", "https://remote.test/users/bob_fr")

      handle_follow(alice, "https://remote.test/users/bob_fr")

      assert [%FollowRequest{follower_uri: "https://remote.test/users/bob_fr"}] = requests(alice.id)
      assert follows(alice.id) == []
    end

    test "authorize turns the request into an accepted follow and clears it" do
      alice = locked_account!("alice_fr2")
      bob = remote_follower!("bob_fr2", "https://remote.test/users/bob_fr2")
      handle_follow(alice, bob.actor_uri)

      assert {:ok, _} = manual(fn -> Follows.authorize(alice.id, bob.id) end)

      assert [%Follow{state: "accepted"}] = follows(alice.id)
      assert requests(alice.id) == []
    end

    test "reject clears the request without creating a follow" do
      alice = locked_account!("alice_fr3")
      bob = remote_follower!("bob_fr3", "https://remote.test/users/bob_fr3")
      handle_follow(alice, bob.actor_uri)

      assert {:ok, _} = manual(fn -> Follows.reject(alice.id, bob.id) end)

      assert requests(alice.id) == []
      assert follows(alice.id) == []
    end
  end

  describe "inbound follow with an invite (FEP-bebd)" do
    test "a valid invite skips the queue even when the account is locked" do
      alice = locked_account!("alice_inv")
      bob = remote_follower!("bob_inv", "https://remote.test/users/bob_inv")
      {:ok, invite} = FollowInvites.mint(alice.id)
      invite_uri = "#{ActorJson.actor_uri(alice.username)}/invites/#{invite.code}"

      handle_follow(alice, bob.actor_uri, invite_uri)

      assert requests(alice.id) == []
      assert [%Follow{state: "accepted"}] = follows(alice.id)
    end

    test "a bogus invite still lands in the queue" do
      alice = locked_account!("alice_inv2")
      bob = remote_follower!("bob_inv2", "https://remote.test/users/bob_inv2")
      bogus = "#{ActorJson.actor_uri(alice.username)}/invites/not-a-real-code"

      handle_follow(alice, bob.actor_uri, bogus)

      assert [%FollowRequest{}] = requests(alice.id)
      assert follows(alice.id) == []
    end
  end

  describe "inbound follow to an unlocked account" do
    test "is accepted immediately (no request queued)" do
      carol = unlocked_account!("carol_fr")
      _dave = remote_follower!("dave_fr", "https://remote.test/users/dave_fr")

      handle_follow(carol, "https://remote.test/users/dave_fr")

      assert requests(carol.id) == []
      assert [%Follow{state: "accepted"}] = follows(carol.id)
    end
  end

  # ── helpers ────────────────────────────────────────────────────────────

  defp handle_follow(followee, follower_uri, instrument \\ nil) do
    followee_uri = ActorJson.actor_uri(followee.username)

    follow =
      %{
        "type" => "Follow",
        "id" => "#{follower_uri}/follows/1",
        "actor" => follower_uri,
        "object" => followee_uri
      }
      |> maybe_put_instrument(instrument)

    save = %{"follow" => follow, "followeeUri" => followee_uri}
    reply = %{"type" => "Accept", "actor" => followee_uri, "object" => follow}
    manual(fn -> Follows.handle_accepted_follow(save, reply, "#{follower_uri}/inbox") end)
  end

  defp maybe_put_instrument(follow, nil), do: follow
  defp maybe_put_instrument(follow, uri), do: Map.put(follow, "instrument", uri)

  # Insert Oban jobs without running them inline — the delivery worker
  # lives on another node and isn't loaded in the gateway test VM.
  defp manual(fun), do: Oban.Testing.with_testing_mode(:manual, fun)

  defp requests(followee_id) do
    Repo.all(from r in FollowRequest, where: r.followee_id == ^followee_id)
  end

  defp follows(followee_id) do
    Repo.all(from f in Follow, where: f.followee_id == ^followee_id)
  end

  defp locked_account!(username), do: account!(username, locked: true)
  defp unlocked_account!(username), do: account!(username, locked: false)

  defp account!(username, locked: locked) do
    %Account{username: username, display_name: username, summary: "", locked: locked}
    |> Repo.insert!()
  end

  defp remote_follower!(username, actor_uri) do
    %Account{
      username: username,
      display_name: username,
      summary: "",
      domain: "remote.test",
      actor_uri: actor_uri,
      inbox_url: "#{actor_uri}/inbox"
    }
    |> Repo.insert!()
  end
end
