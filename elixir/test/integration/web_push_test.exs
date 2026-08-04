# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Integration.WebPushTest do
  use SukhiFedi.IntegrationCase, async: false

  @moduletag :integration

  alias SukhiFedi.Addons.WebPush
  alias SukhiFedi.Schema.Account

  describe "subscribe/5 + get_subscription_for/1" do
    test "upserts on (account, endpoint) and surfaces the most-recent row" do
      alice = create_account!("alice_wp")

      endpoint = "https://push.example/sub/1"
      {:ok, _} = WebPush.subscribe(alice.id, endpoint, "p256dh", "auth", %{"mention" => true})

      # Same endpoint re-issued with different alerts → row is replaced.
      {:ok, _} = WebPush.subscribe(alice.id, endpoint, "p256dh", "auth", %{"mention" => false})

      sub = WebPush.get_subscription_for(alice.id)
      assert sub.endpoint == endpoint
      assert sub.alerts == %{"mention" => false}

      case WebPush.unsubscribe(endpoint) do
        {n, _} when n >= 0 -> :ok
        :ok -> :ok
      end

      assert WebPush.get_subscription_for(alice.id) == nil
    end

    test "server_key reads from app config" do
      # The public half now lives with its private twin and the VAPID
      # subject under one `:web_push` key, instead of alone at
      # `:vapid_public_key` — the three are only ever set together, and
      # push is off unless all three are.
      Application.put_env(:sukhi_fedi, :web_push, public_key: "test-key")
      assert WebPush.server_key() == "test-key"
      assert WebPush.configured?()

      Application.delete_env(:sukhi_fedi, :web_push)
      assert WebPush.server_key() == nil
      refute WebPush.configured?()
    end
  end

  defp create_account!(username) do
    %Account{username: username, display_name: username, summary: ""}
    |> Repo.insert!()
  end
end
