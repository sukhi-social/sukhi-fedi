# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Integration.AccountPorterTest do
  @moduledoc """
  Export / import of follows, blocks and mutes: CSV out, CSV in, resolved
  against accounts the server already knows (no network).
  """

  use SukhiFedi.IntegrationCase, async: false

  @moduletag :integration

  alias SukhiFedi.AccountPorter
  alias SukhiFedi.Addons.Moderation
  alias SukhiFedi.Schema.Account

  defp create_account!(username) do
    %Account{username: username, display_name: username, summary: ""} |> Repo.insert!()
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

  test "blocks round-trip: export lists them, import into another account applies them" do
    alice = create_account!("porter_alice")
    zed = create_account!("porter_zed")
    bob = create_remote_account!("porter_bob", "remote.example")
    carol = create_account!("porter_carol")

    {:ok, _} = Moderation.block(alice.id, bob.id)
    {:ok, _} = Moderation.block(alice.id, carol.id)

    {:ok, csv} = AccountPorter.export(alice.id, :blocks)
    local = SukhiFedi.Config.domain!()

    assert csv ==
             "Account address\r\n" <>
               "porter_bob@remote.example\r\nporter_carol@#{local}\r\n"

    assert {:ok, %{imported: 2, skipped: 0, unresolved: []}} =
             AccountPorter.import_csv(zed.id, :blocks, csv)

    assert Moderation.blocked?(zed.id, bob.id)
    assert Moderation.blocked?(zed.id, carol.id)
  end

  test "mutes import is idempotent and never targets the importer itself" do
    alice = create_account!("porter_self")
    bob = create_account!("porter_mutee")
    local = SukhiFedi.Config.domain!()
    csv = "Account address\n#{alice.username}@#{local}\n#{bob.username}\n"

    assert {:ok, %{imported: 1}} = AccountPorter.import_csv(alice.id, :mutes, csv)
    assert {:ok, %{imported: 1}} = AccountPorter.import_csv(alice.id, :mutes, csv)
    assert Moderation.muted?(alice.id, bob.id)
    refute Moderation.muted?(alice.id, alice.id)
  end

  test "follows import creates the follow rows for known accounts" do
    alice = create_account!("porter_follower")
    bob = create_account!("porter_followee")

    assert {:ok, %{imported: 1}} = AccountPorter.import_csv(alice.id, :following, "#{bob.username}\n")

    {:ok, csv} = AccountPorter.export(alice.id, :following)
    assert csv == "Account address\r\n#{bob.username}@#{SukhiFedi.Config.domain!()}\r\n"
  end
end
