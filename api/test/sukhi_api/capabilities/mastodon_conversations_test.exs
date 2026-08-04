# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiApi.Capabilities.MastodonConversationsTest do
  @moduledoc """
  The Link header on a conversation's statuses.

  A page without it still answers 200 with the right messages, so nothing
  looks wrong from here — but the client's pager reads `rel="next"` to
  decide whether to show 「もっと読む」, and with no cursor it shows
  nothing. From the outside that reads as a conversation *losing its old
  messages*: as new ones arrive they push the older ones past the first
  page, and there is no way back to them.

  That is how this endpoint shipped. The test exists so the header is
  something the endpoint promises, not something it happens to do.
  """
  use ExUnit.Case, async: false

  alias SukhiApi.Router

  defmodule FakeRpc do
    def call(mod, fun, args), do: call(mod, fun, args, 5_000)
    def call(SukhiFedi.Conversations, fun, args, _t), do: lookup(:fake_convos, fun, args)
    def call(SukhiFedi.OAuth, fun, args, _t), do: lookup(:fake_oauth, fun, args)
    def call(_, _, _, _), do: {:error, :not_connected}

    defp lookup(env_key, fun, args) do
      table = Application.get_env(:sukhi_api, env_key, %{})

      case Map.get(table, {fun, args}, :not_configured) do
        :not_configured ->
          case Map.get(table, fun, :not_configured) do
            :not_configured -> {:error, :not_connected}
            v -> {:ok, v}
          end

        v ->
          {:ok, v}
      end
    end
  end

  setup do
    prev = %{
      rpc: Application.get_env(:sukhi_api, :gateway_rpc_impl),
      addons: Application.get_env(:sukhi_api, :enabled_addons),
      convos: Application.get_env(:sukhi_api, :fake_convos),
      oauth: Application.get_env(:sukhi_api, :fake_oauth)
    }

    Application.put_env(:sukhi_api, :gateway_rpc_impl, FakeRpc)
    Application.put_env(:sukhi_api, :enabled_addons, :all)

    on_exit(fn ->
      for {k, v} <- [
            gateway_rpc_impl: prev.rpc,
            enabled_addons: prev.addons,
            fake_convos: prev.convos,
            fake_oauth: prev.oauth
          ] do
        if is_nil(v),
          do: Application.delete_env(:sukhi_api, k),
          else: Application.put_env(:sukhi_api, k, v)
      end
    end)

    :ok
  end

  defp account, do: %{id: 1, username: "alice", display_name: "A", summary: "", is_bot: false}

  defp note(id) do
    %{
      id: id,
      content: "m#{id}",
      visibility: "direct",
      ap_id: nil,
      cw: nil,
      in_reply_to_ap_id: nil,
      created_at: ~U[2026-08-04 00:00:00Z],
      account: account(),
      media: []
    }
  end

  defp authed_get(path, query) do
    Application.put_env(:sukhi_api, :fake_oauth, %{
      verify_bearer: {:ok, %{account: account(), app: %{id: 1, name: "x"}, scopes: ["read"]}}
    })

    %{method: "GET", path: path, query: query, headers: [{"authorization", "Bearer t"}]}
  end

  defp link_of(resp) do
    Enum.find_value(resp.headers, fn {k, v} -> if String.downcase(k) == "link", do: v end)
  end

  describe "GET /api/v1/conversations/:id/statuses" do
    test "carries a Link header so the thread can be read backwards" do
      Application.put_env(:sukhi_api, :fake_convos, %{statuses: {:ok, [note(30), note(20), note(10)]}})

      {:ok, resp} = Router.handle(authed_get("/api/v1/conversations/5/statuses", "limit=3"))

      assert resp.status == 200
      assert length(JSON.decode!(resp.body)) == 3

      link = link_of(resp)
      assert link =~ ~s(rel="next"), "without this the client hides 「もっと読む」"
      # The cursor is the *oldest* id on the page — that is what "further
      # back" means here.
      assert link =~ "max_id=10"
      assert link =~ "/api/v1/conversations/5/statuses"
    end

    test "no Link on the last page, so the button goes away" do
      Application.put_env(:sukhi_api, :fake_convos, %{statuses: {:ok, []}})

      {:ok, resp} = Router.handle(authed_get("/api/v1/conversations/5/statuses", "limit=20"))

      assert resp.status == 200
      assert JSON.decode!(resp.body) == []
      assert link_of(resp) == nil
    end
  end
end
