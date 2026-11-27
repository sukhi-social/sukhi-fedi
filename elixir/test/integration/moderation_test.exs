# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Integration.ModerationTest do
  use SukhiFedi.IntegrationCase, async: false

  @moduletag :integration

  alias SukhiFedi.Addons.Moderation
  alias SukhiFedi.Schema.Account

  describe "blocks" do
    test "block then list_blocks hydrates the target's account row" do
      alice = create_account!("alice_mb")
      bob = create_account!("bob_mb")

      {:ok, _} = Moderation.block(alice.id, bob.id)
      assert Moderation.blocked?(alice.id, bob.id) == true

      [row] = Moderation.list_blocks(alice.id)
      assert row.id == bob.id
      assert row.username == "bob_mb"
    end

    test "unblock is idempotent" do
      alice = create_account!("alice_mb2")
      bob = create_account!("bob_mb2")

      {:ok, _} = Moderation.block(alice.id, bob.id)
      assert {1, _} = Moderation.unblock(alice.id, bob.id)
      assert {0, _} = Moderation.unblock(alice.id, bob.id)
      assert Moderation.blocked?(alice.id, bob.id) == false
    end
  end

  describe "mutes" do
    test "expired mutes are excluded from list_mutes" do
      alice = create_account!("alice_mm")
      bob = create_account!("bob_mm")
      carol = create_account!("carol_mm")

      {:ok, _} = Moderation.mute(alice.id, bob.id, nil)
      past = DateTime.utc_now() |> DateTime.add(-1, :hour) |> DateTime.truncate(:second)
      {:ok, _} = Moderation.mute(alice.id, carol.id, past)

      ids = Moderation.list_mutes(alice.id) |> Enum.map(& &1.id) |> Enum.sort()
      assert ids == [bob.id]
    end
  end

  describe "reports" do
    test "create_report defaults to open status" do
      alice = create_account!("alice_rep")
      bob = create_account!("bob_rep")

      assert {:ok, r} =
               Moderation.create_report(%{
                 account_id: alice.id,
                 target_id: bob.id,
                 comment: "spam"
               })

      assert r.status == "open"
      assert r.target_id == bob.id
    end
  end

  describe "instance_policy/1" do
    test "maps stored severity to a federation decision; unblocked is :pass" do
      admin = create_account!("ip_admin")

      {:ok, _} = Moderation.block_instance("loud.example", "silence", "noisy", admin.id)
      {:ok, _} = Moderation.block_instance("evil.example", "suspend", "abuse", admin.id)

      assert Moderation.instance_policy("loud.example") == :silence
      assert Moderation.instance_policy("evil.example") == :reject
      assert Moderation.instance_policy("friendly.example") == :pass
      assert Moderation.instance_policy(nil) == :pass
    end

    test "silenced_author_ids/0 returns only accounts on :silence instances" do
      admin = create_account!("sa_admin")

      {:ok, _} = Moderation.block_instance("loud.example", "silence", nil, admin.id)
      {:ok, _} = Moderation.block_instance("evil.example", "suspend", nil, admin.id)

      silenced = create_remote_account!("noisy", "loud.example")
      _suspended = create_remote_account!("crook", "evil.example")
      _local = create_account!("homebody")

      assert Moderation.silenced_author_ids() == [silenced.id]
    end
  end

  defp create_account!(username) do
    %Account{username: username, display_name: username, summary: ""}
    |> insert_account!()
  end

  defp create_remote_account!(username, domain) do
    %Account{
      username: username,
      domain: domain,
      display_name: username,
      summary: "",
      actor_uri: "https://#{domain}/users/#{username}"
    }
    |> insert_account!()
  end
end
