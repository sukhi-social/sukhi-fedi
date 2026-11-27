# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Integration.AccountMigrationTest do
  @moduledoc """
  Account migration (Mastodon Move + alsoKnownAs):

    * the bidirectional-consent predicate, and
    * the inbound Move follow re-point Multi (insert new + Undo old, both
      riding the transactional outbox).
  """

  use SukhiFedi.IntegrationCase, async: false

  @moduletag :integration

  import Ecto.Query

  alias SukhiFedi.AP.Instructions.Migrations
  alias SukhiFedi.Schema.{Account, Follow, OutboxEvent}

  @old_uri "https://old.example/users/mover"
  @new_uri "https://new.example/users/mover"

  describe "bidirectional_consent?/2" do
    test "true only when the new actor lists the old uri in its aliases" do
      consenting = %Account{aliases: [@old_uri, "https://other.example/users/x"]}
      assert Migrations.bidirectional_consent?(@old_uri, consenting)
    end

    test "false when the new actor does not list the old uri" do
      silent = %Account{aliases: ["https://other.example/users/x"]}
      refute Migrations.bidirectional_consent?(@old_uri, silent)
    end

    test "false when the new actor has no aliases at all" do
      bare = %Account{aliases: []}
      refute Migrations.bidirectional_consent?(@old_uri, bare)
      refute Migrations.bidirectional_consent?(@old_uri, %Account{aliases: nil})
    end
  end

  describe "maybe_handle_move/1 — follow re-point" do
    test "re-points a consenting move: new follow + Undo old, both on the outbox" do
      alice = create_account!("alice_move")
      old = create_remote_account!("mover", "old.example")
      _new = create_remote_account!("mover", "new.example", aliases: [@old_uri])

      old_follow = create_follow!(alice, old.id, "accepted")

      :ok =
        Migrations.maybe_handle_move(%{
          "type" => "Move",
          "actor" => @old_uri,
          "target" => @new_uri
        })

      # The old edge is gone; a new edge to `new` exists (pending — the new
      # server's Accept will flip it).
      refute Repo.get(Follow, old_follow.id)

      new_account = Repo.get_by!(Account, actor_uri: @new_uri)
      new_follow = Repo.get_by!(Follow, follower_uri: alice_uri(alice), followee_id: new_account.id)
      assert new_follow.state == "pending"

      # Both sides ride the transactional outbox: a Follow to the new
      # identity and an Undo(Follow) of the old one.
      assert outbox_count("sns.outbox.follow.requested", new_follow.id) == 1
      assert outbox_count("sns.outbox.follow.undone", old_follow.id) == 1

      # The old shadow is quietly stamped as moved.
      assert Repo.get_by!(Account, actor_uri: @old_uri).moved_to_uri == @new_uri
    end

    test "no consent ⇒ no re-point, no outbox, no moved stamp" do
      alice = create_account!("alice_noconsent")
      old = create_remote_account!("mover", "old.example")
      _new = create_remote_account!("mover", "new.example", aliases: [])

      old_follow = create_follow!(alice, old.id, "accepted")

      :ok =
        Migrations.maybe_handle_move(%{
          "type" => "Move",
          "actor" => @old_uri,
          "target" => @new_uri
        })

      # Untouched: the old follow stays, no new edge, no outbox, not moved.
      assert Repo.get(Follow, old_follow.id)
      new_account = Repo.get_by!(Account, actor_uri: @new_uri)
      refute Repo.get_by(Follow, follower_uri: alice_uri(alice), followee_id: new_account.id)
      assert outbox_count("sns.outbox.follow.undone", old_follow.id) == 0
      assert Repo.get_by!(Account, actor_uri: @old_uri).moved_to_uri == nil
    end

    test "already following the new identity ⇒ only the old edge is undone" do
      alice = create_account!("alice_dup")
      old = create_remote_account!("mover", "old.example")
      new = create_remote_account!("mover", "new.example", aliases: [@old_uri])

      old_follow = create_follow!(alice, old.id, "accepted")
      _existing_new = create_follow!(alice, new.id, "accepted")

      :ok =
        Migrations.maybe_handle_move(%{
          "type" => "Move",
          "actor" => @old_uri,
          "target" => @new_uri
        })

      # Old undone; the pre-existing edge to `new` is the only one left and
      # no duplicate Follow went out.
      refute Repo.get(Follow, old_follow.id)
      assert outbox_count("sns.outbox.follow.undone", old_follow.id) == 1

      n =
        Repo.aggregate(
          from(f in Follow,
            where: f.follower_uri == ^alice_uri(alice) and f.followee_id == ^new.id
          ),
          :count,
          :id
        )

      assert n == 1
    end
  end

  # ── helpers ───────────────────────────────────────────────────────────────

  defp create_account!(username) do
    %Account{username: username, display_name: username, summary: ""}
    |> Repo.insert!()
  end

  defp create_remote_account!(username, domain, opts \\ []) do
    %Account{
      username: username,
      display_name: username,
      summary: "",
      domain: domain,
      actor_uri: "https://#{domain}/users/#{username}",
      inbox_url: "https://#{domain}/users/#{username}/inbox",
      aliases: Keyword.get(opts, :aliases, [])
    }
    |> Repo.insert!()
  end

  defp create_follow!(%Account{} = follower, followee_id, state) do
    %Follow{follower_uri: alice_uri(follower), followee_id: followee_id, state: state}
    |> Repo.insert!()
  end

  defp alice_uri(%Account{username: u}), do: "https://#{SukhiFedi.Config.domain!()}/users/#{u}"

  defp outbox_count(subject, aggregate_id) do
    SukhiFedi.AccountRepo.aggregate(
      from(e in OutboxEvent,
        where: e.subject == ^subject and e.aggregate_id == ^to_string(aggregate_id)
      ),
      :count,
      :id
    )
  end
end
