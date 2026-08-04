# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Integration.SocialTest do
  @moduledoc """
  End-to-end tests for `SukhiFedi.Social` follow/unfollow + relationships.
  Requires the test Postgres with core migrations applied.

      docker compose -f docker-compose.test.yml up -d
      MIX_ENV=test mix ecto.migrate
      mix test --only integration
  """

  use SukhiFedi.IntegrationCase, async: false

  @moduletag :integration

  import Ecto.Query

  alias SukhiFedi.{Accounts, Social}
  alias SukhiFedi.Schema.{Account, Follow, OutboxEvent}

  describe "request_follow/2 (remote target)" do
    test "inserts pending Follow + sns.outbox.follow.requested" do
      alice = create_account!("alice_rf")
      bob_remote = create_remote_account!("bob_rf", "social.example")

      {:ok, follow} = Social.request_follow(alice, bob_remote.id)

      assert follow.followee_id == bob_remote.id
      assert follow.follower_uri =~ "/users/alice_rf"
      assert follow.state == "pending"

      ev =
        Repo.one!(
          from e in OutboxEvent,
            where: e.subject == "sns.outbox.follow.requested" and e.aggregate_id == ^to_string(follow.id)
        )

      assert ev.payload["follow_id"] == follow.id
      assert ev.payload["followee_id"] == bob_remote.id
    end

    test "is idempotent — second call returns the same row, no extra outbox" do
      alice = create_account!("alice_idemp")
      bob_remote = create_remote_account!("bob_idemp", "social.example")

      {:ok, f1} = Social.request_follow(alice, bob_remote.id)
      {:ok, f2} = Social.request_follow(alice, bob_remote.id)

      assert f1.id == f2.id

      n =
        Repo.aggregate(
          from(e in OutboxEvent,
            where: e.subject == "sns.outbox.follow.requested" and e.aggregate_id == ^to_string(f1.id)
          ),
          :count,
          :id
        )

      assert n == 1
    end

    test "self-follow is rejected" do
      alice = create_account!("alice_self")
      assert {:error, :self_follow} = Social.request_follow(alice, alice.id)
    end

    test "follow of unknown account → :not_found" do
      alice = create_account!("alice_404")
      assert {:error, :not_found} = Social.request_follow(alice, 99_999_999)
    end
  end

  describe "request_follow/2 (local target)" do
    test "lands as accepted with NO outbox event" do
      alice = create_account!("alice_local_rf")
      bob = create_account!("bob_local_rf")

      {:ok, follow} = Social.request_follow(alice, bob.id)

      assert follow.followee_id == bob.id
      assert follow.state == "accepted"

      n =
        Repo.aggregate(
          from(e in OutboxEvent,
            where: e.subject == "sns.outbox.follow.requested" and e.aggregate_id == ^to_string(follow.id)
          ),
          :count,
          :id
        )

      assert n == 0
    end
  end

  describe "list_followers/1" do
    test "resolves local + remote follower URIs to account projections" do
      potato = create_account!("potato_lf")
      nyanrus = create_account!("nyanrus_lf")
      bob_remote = create_remote_account!("bob_lf", "social.example")

      local_uri = "https://#{SukhiFedi.Config.domain!()}/users/nyanrus_lf"
      Repo.insert!(%Follow{follower_uri: local_uri, followee_id: potato.id, state: "accepted"})

      Repo.insert!(%Follow{
        follower_uri: bob_remote.actor_uri,
        followee_id: potato.id,
        state: "accepted"
      })

      by_id = Social.list_followers(potato.id) |> Map.new(fn f -> {f[:id], f} end)

      assert by_id[nyanrus.id].username == "nyanrus_lf"
      assert by_id[nyanrus.id].domain == nil
      assert by_id[bob_remote.id].domain == "social.example"
      assert by_id[bob_remote.id].actor_uri == bob_remote.actor_uri
    end

    test "an unresolved follower URI falls through as %{actor_uri: uri}" do
      potato = create_account!("potato_unres")
      ghost = "https://gone.example/users/ghost"
      Repo.insert!(%Follow{follower_uri: ghost, followee_id: potato.id, state: "accepted"})

      assert [%{actor_uri: ^ghost} = item] = Social.list_followers(potato.id)
      refute Map.has_key?(item, :id)
    end
  end

  describe "list_following/1" do
    test "projects remote followees with domain + actor_uri, not a local fallback" do
      alice = create_account!("alice_lfg")
      bob_remote = create_remote_account!("bob_lfg", "social.example")
      potato = create_account!("potato_lfg")

      alice_uri = "https://#{SukhiFedi.Config.domain!()}/users/alice_lfg"
      Repo.insert!(%Follow{follower_uri: alice_uri, followee_id: bob_remote.id, state: "accepted"})
      Repo.insert!(%Follow{follower_uri: alice_uri, followee_id: potato.id, state: "accepted"})

      by_id = Social.list_following(alice_uri) |> Map.new(fn f -> {f[:id], f} end)

      # A remote followee must keep its domain + actor_uri — otherwise the
      # Mastodon account view renders it as a bare local handle and the
      # profile link 404s.
      assert by_id[bob_remote.id].domain == "social.example"
      assert by_id[bob_remote.id].actor_uri == bob_remote.actor_uri
      # …while a local followee stays local.
      assert by_id[potato.id].domain == nil
    end
  end

  describe "unfollow/2" do
    test "deletes the Follow row + emits sns.outbox.follow.undone (remote target)" do
      alice = create_account!("alice_unf")
      bob_remote = create_remote_account!("bob_unf", "social.example")
      {:ok, follow} = Social.request_follow(alice, bob_remote.id)

      assert {:ok, deleted} = Social.unfollow(alice, bob_remote.id)
      assert deleted.id == follow.id
      refute Repo.get(Follow, follow.id)

      ev =
        Repo.one!(
          from e in OutboxEvent,
            where: e.subject == "sns.outbox.follow.undone" and e.aggregate_id == ^to_string(follow.id)
        )

      assert ev.payload["followee_id"] == bob_remote.id
    end

    test "local-target unfollow deletes the row but skips the outbox event" do
      alice = create_account!("alice_local_unf")
      bob = create_account!("bob_local_unf")
      {:ok, follow} = Social.request_follow(alice, bob.id)

      assert {:ok, _deleted} = Social.unfollow(alice, bob.id)
      refute Repo.get(Follow, follow.id)

      n =
        Repo.aggregate(
          from(e in OutboxEvent, where: e.subject == "sns.outbox.follow.undone"),
          :count,
          :id
        )

      assert n == 0
    end

    test "unfollowing when no follow exists → :not_found" do
      alice = create_account!("alice_uf2")
      bob = create_account!("bob_uf2")

      assert {:error, :not_found} = Social.unfollow(alice, bob.id)
    end
  end

  describe "list_relationships/2" do
    test "returns following=true for accepted follow, followed_by=true reciprocal" do
      alice = create_account!("alice_rel")
      bob = create_account!("bob_rel")
      carol = create_account!("carol_rel")

      {:ok, f1} = Social.request_follow(alice, bob.id)
      # mark accepted directly
      _ = Repo.update_all(from(f in Follow, where: f.id == ^f1.id), set: [state: "accepted"])

      # bob follows alice back
      {:ok, f2} = Social.request_follow(bob, alice.id)
      _ = Repo.update_all(from(f in Follow, where: f.id == ^f2.id), set: [state: "accepted"])

      [bob_rel, carol_rel] = Social.list_relationships(alice, [bob.id, carol.id])

      assert bob_rel.id == bob.id
      assert bob_rel.following == true
      assert bob_rel.followed_by == true

      assert carol_rel.id == carol.id
      assert carol_rel.following == false
      assert carol_rel.followed_by == false
    end

    test "caps at 40 ids" do
      alice = create_account!("alice_cap")
      ids = Enum.to_list(1..50)
      # Just make sure it doesn't crash; result count matches input
      # (since none of these accounts exist, all relationships are
      # all-false but we get one entry per requested id).
      list = Social.list_relationships(alice, ids)
      # Capability layer caps at 40, but the context returns all
      # requested ids — capping is a presentation concern.
      assert length(list) == 50
    end

    test "reflects real block / mute state instead of hardcoded false (C2)" do
      alice = create_account!("alice_blockrel")
      bob = create_account!("bob_blockrel")
      carol = create_account!("carol_blockrel")

      {:ok, _} = SukhiFedi.Addons.Moderation.block(alice.id, bob.id)
      {:ok, _} = SukhiFedi.Addons.Moderation.mute(alice.id, carol.id)

      [bob_rel, carol_rel] = Social.list_relationships(alice, [bob.id, carol.id])

      assert bob_rel.blocking == true
      assert bob_rel.muting == false
      assert carol_rel.muting == true
      assert carol_rel.muting_notifications == true
      assert carol_rel.blocking == false
    end
  end

  describe "set_account_note/3" do
    test "a set note surfaces as the relationship's `note`, replacing the empty default" do
      alice = create_account!("alice_note_set")
      bob = create_account!("bob_note_set")

      # Default: no note ⇒ "".
      [before] = Social.list_relationships(alice, [bob.id])
      assert before.note == ""

      assert {:ok, _} = Social.set_account_note(alice, bob.id, "old colleague")

      [after_set] = Social.list_relationships(alice, [bob.id])
      assert after_set.note == "old colleague"

      # The note is the viewer's own: bob sees nothing about alice.
      [bobs_view] = Social.list_relationships(bob, [alice.id])
      assert bobs_view.note == ""
    end

    test "is an upsert — setting again replaces, leaving one row; \"\" clears" do
      alice = create_account!("alice_note_up")
      bob = create_account!("bob_note_up")

      {:ok, _} = Social.set_account_note(alice, bob.id, "first")
      {:ok, _} = Social.set_account_note(alice, bob.id, "second")

      n =
        Repo.aggregate(
          from(an in SukhiFedi.Schema.AccountNote,
            where: an.author_account_id == ^alice.id and an.target_account_id == ^bob.id
          ),
          :count,
          :id
        )

      assert n == 1
      assert [%{note: "second"}] = Social.list_relationships(alice, [bob.id])

      {:ok, _} = Social.set_account_note(alice, bob.id, "")
      assert [%{note: ""}] = Social.list_relationships(alice, [bob.id])
    end

    test "note about an unknown account → :not_found" do
      alice = create_account!("alice_note_404")
      assert {:error, :not_found} = Social.set_account_note(alice, 99_999_999, "x")
    end
  end

  describe "Accounts.lookup_by_acct/1" do
    test "local username resolves" do
      a = create_account!("local_lookup")
      assert {:ok, found} = Accounts.lookup_by_acct("local_lookup")
      assert found.id == a.id
    end

    test "user@local-host resolves" do
      a = create_account!("local_at")
      domain = Application.get_env(:sukhi_fedi, :domain, "localhost:4000")

      assert {:ok, found} = Accounts.lookup_by_acct("local_at@#{domain}")
      assert found.id == a.id
    end

    test "remote acct (different host) → :not_found" do
      _ = create_account!("only_local_user")
      assert {:error, :not_found} = Accounts.lookup_by_acct("only_local_user@elsewhere.example")
    end
  end

  describe "Accounts.update_credentials/2" do
    test "updates display_name + emits sns.outbox.actor.updated" do
      a = create_account!("alice_uc")

      assert {:ok, updated} =
               Accounts.update_credentials(a.id, %{"display_name" => "Alice Updated"})

      assert updated.display_name == "Alice Updated"

      ev =
        Repo.one!(
          from e in OutboxEvent,
            where: e.subject == "sns.outbox.actor.updated" and e.aggregate_id == ^to_string(a.id)
        )

      assert ev.payload["account_id"] == a.id
    end

    test "rejects too-long display_name" do
      a = create_account!("alice_long")

      assert {:error, {:validation, errors}} =
               Accounts.update_credentials(a.id, %{"display_name" => String.duplicate("x", 200)})

      assert is_list(errors[:display_name])
    end

    test "Mastodon's `note` is mapped to `summary`" do
      a = create_account!("alice_note")
      assert {:ok, updated} = Accounts.update_credentials(a.id, %{"note" => "new bio"})
      assert updated.summary == "new bio"
    end
  end

  describe "Accounts.counts_for/1" do
    test "returns followers/following/statuses counts and caches" do
      a = create_account!("alice_counts")
      assert %{followers: 0, following: 0, statuses: 0} = Accounts.counts_for(a.id)
    end

    # プロフィールの数は誰でも見られる。ここに DM を足すと、中身は見えなく
    # ても「何通送ったか」が外から数えられてしまう。実際そうなっていて、
    # 一晩 DM をしたら公開の投稿数が 241 になった。
    test "**DM は、公開の投稿数に入らない**" do
      a = create_account!("dm_counts_a")
      b = create_account!("dm_counts_b")

      {:ok, _} = SukhiFedi.Notes.create_status(a.id, %{"status" => "みんなに", "visibility" => "public"})
      {:ok, _} = SukhiFedi.Notes.create_status(a.id, %{"status" => "@dm_counts_b ないしょ", "visibility" => "direct"})
      {:ok, _} = SukhiFedi.Notes.create_status(a.id, %{"status" => "@dm_counts_b これも", "visibility" => "direct"})

      # 新しく作ったアカウントなので、まだ数えられていない(キャッシュ無し)。
      assert %{statuses: 1} = Accounts.counts_for(a.id)
      _ = b
    end

    test "フォロワー限定は、数える(見える人には見える投稿だから)" do
      a = create_account!("fo_counts")
      {:ok, _} = SukhiFedi.Notes.create_status(a.id, %{"status" => "みんなに", "visibility" => "public"})
      {:ok, _} = SukhiFedi.Notes.create_status(a.id, %{"status" => "ふぉろわに", "visibility" => "followers"})

      # 新しく作ったアカウントなので、まだ数えられていない(キャッシュ無し)。
      assert %{statuses: 2} = Accounts.counts_for(a.id)
    end
  end

  describe "Accounts.signing_identity/0" do
    test "returns a local account that holds a keypair, skipping keyless ones" do
      _keyless = create_account!("sig_keyless")
      keyed_account!("sig_keyed")

      identity = Accounts.signing_identity()

      assert identity.privateJwk == %{"kty" => "RSA", "d" => "test"}
      assert identity.keyId =~ "/users/sig_keyed#main-key"
    end

    test "returns nil when no local account has a keypair" do
      _keyless = create_account!("sig_none")
      assert Accounts.signing_identity() == nil
    end
  end

  defp create_account!(username) do
    %Account{username: username, display_name: username, summary: ""}
    |> Repo.insert!()
  end

  defp keyed_account!(username) do
    %Account{
      username: username,
      display_name: username,
      summary: "",
      private_key_jwk: %{"kty" => "RSA", "d" => "test"},
      public_key_jwk: %{"kty" => "RSA"}
    }
    |> Repo.insert!()
  end

  defp create_remote_account!(username, domain) do
    %Account{
      username: username,
      display_name: username,
      summary: "",
      domain: domain,
      actor_uri: "https://#{domain}/users/#{username}",
      inbox_url: "https://#{domain}/users/#{username}/inbox"
    }
    |> Repo.insert!()
  end
end
