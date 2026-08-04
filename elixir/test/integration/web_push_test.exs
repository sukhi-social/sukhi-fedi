# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Integration.WebPushTest do
  use SukhiFedi.IntegrationCase, async: false

  @moduletag :integration

  import Ecto.Query, only: [from: 2]

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

    test "a mention actually enqueues a push, and a favourite does not" do
      # The end of the chain that `deliverable?/3`'s unit tests can't see:
      # a *job* has to come out the other side. It didn't, for a while —
      # `Oban.insert/1` looks for a default instance and this app names
      # its own, so every push raised, `notify/1`'s rescue returned :ok,
      # and nothing was logged. Green predicate tests, zero pushes.
      alice = create_account!("push_alice")
      bob = create_account!("push_bob")

      Application.put_env(:sukhi_fedi, :web_push, public_key: "test-key")
      on_exit(fn -> Application.delete_env(:sukhi_fedi, :web_push) end)

      {:ok, _} =
        WebPush.subscribe(alice.id, "https://push.example/enqueue-1", "p256dh", "auth", %{
          "mention" => true,
          "favourite" => true
        })

      pushes = fn ->
        SukhiFedi.Repo.aggregate(from(j in "oban_jobs", where: j.queue == "push"), :count)
      end

      # `:manual`, because the test env otherwise runs jobs inline at insert
      # and this job's worker lives on the *delivery* node — which is the
      # design, not an accident. Here we only care that the job is written.
      Oban.Testing.with_testing_mode(:manual, fn ->
        before = pushes.()

        {:ok, mention} =
          SukhiFedi.Notifications.create(%{
            account_id: alice.id,
            from_account_id: bob.id,
            type: "mention",
            note_id: nil
          })

        refute is_nil(mention.id), "a fresh row is needed for the doorbell to ring at all"
        assert pushes.() == before + 1, "a mention must reach the push queue"

        # And the calm contract survives the whole chain, not just the
        # predicate: the same subscription, alerts on, produces nothing.
        SukhiFedi.Notifications.create(%{
          account_id: alice.id,
          from_account_id: bob.id,
          type: "favourite",
          note_id: nil
        })

        assert pushes.() == before + 1, "a favourite must never reach the push queue"
      end)
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
