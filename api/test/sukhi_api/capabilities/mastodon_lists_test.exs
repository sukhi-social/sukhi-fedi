# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiApi.Capabilities.MastodonListsTest do
  use ExUnit.Case, async: false

  alias SukhiApi.Router

  defmodule FakeRpc do
    def call(mod, fun, args), do: call(mod, fun, args, 5_000)

    def call(SukhiFedi.Lists, fun, args, _t), do: lookup(:fake_lists, fun, args)
    def call(SukhiFedi.Timelines, fun, args, _t), do: lookup(:fake_timelines, fun, args)
    def call(SukhiFedi.OAuth, fun, args, _t), do: lookup(:fake_oauth, fun, args)
    # Notes / PreviewCards hydration is unconfigured here; StatusHydration
    # treats not_connected as empty context and renders anyway.
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
      lists: Application.get_env(:sukhi_api, :fake_lists),
      tl: Application.get_env(:sukhi_api, :fake_timelines),
      oauth: Application.get_env(:sukhi_api, :fake_oauth)
    }

    Application.put_env(:sukhi_api, :gateway_rpc_impl, FakeRpc)
    Application.put_env(:sukhi_api, :enabled_addons, :all)
    Application.put_env(:sukhi_api, :fake_lists, %{})
    Application.put_env(:sukhi_api, :fake_timelines, %{})

    Application.put_env(:sukhi_api, :fake_oauth, %{
      verify_bearer:
        {:ok,
         %{
           account: account(),
           app: %{id: 1, name: "x"},
           scopes: ["read:lists", "write:lists"]
         }}
    })

    on_exit(fn ->
      restore(:gateway_rpc_impl, prev.rpc)
      restore(:enabled_addons, prev.addons)
      restore(:fake_lists, prev.lists)
      restore(:fake_timelines, prev.tl)
      restore(:fake_oauth, prev.oauth)
    end)

    :ok
  end

  defp account, do: %{id: 1, username: "alice", display_name: "A", summary: "", is_bot: false}

  defp note(id) do
    %{
      id: id,
      content: "n#{id}",
      visibility: "public",
      ap_id: "https://x.example/notes/#{id}",
      cw: nil,
      in_reply_to_ap_id: nil,
      created_at: ~U[2026-04-21 00:00:00Z],
      account: account(),
      media: []
    }
  end

  defp list_row(id, title) do
    %{
      id: id,
      title: title,
      replies_policy: "list",
      exclusive: false,
      filter_only_media: false,
      filter_hide_boosts: false,
      filter_hide_sensitive: false,
      filter_keyword: "",
      filter_replies: "all"
    }
  end

  defp authed_get(path, query \\ "") do
    %{method: "GET", path: path, query: query, headers: [{"authorization", "Bearer t"}]}
  end

  describe "GET /api/v1/lists" do
    test "ご近所 rides at the front, ahead of the reader's own lists" do
      Application.put_env(:sukhi_api, :fake_lists, %{list_for: [list_row(7, "Friends")]})

      {:ok, resp} = Router.handle(authed_get("/api/v1/lists"))

      assert resp.status == 200
      body = JSON.decode!(resp.body)
      assert hd(body)["id"] == "bubble"
      assert hd(body)["title"] == "ご近所"
      assert Enum.at(body, 1)["id"] == "7"
    end

    test "Korean reader (Accept-Language) → ご近所 shows its Korean title" do
      Application.put_env(:sukhi_api, :fake_lists, %{list_for: []})

      {:ok, resp} =
        Router.handle(%{
          method: "GET",
          path: "/api/v1/lists",
          query: "",
          headers: [{"authorization", "Bearer t"}, {"accept-language", "ko"}]
        })

      assert resp.status == 200
      assert resp.body |> JSON.decode!() |> hd() |> Map.get("title") == "이웃"
    end
  end

  describe "GET /api/v1/timelines/list/bubble" do
    test "returns the curated bubble feed" do
      Application.put_env(:sukhi_api, :fake_timelines, %{bubble: [note(2), note(1)]})

      {:ok, resp} = Router.handle(authed_get("/api/v1/timelines/list/bubble", "limit=2"))

      assert resp.status == 200
      body = JSON.decode!(resp.body)
      assert length(body) == 2
      assert hd(body)["id"] == "2"
    end
  end

  describe "ご近所 is read-only" do
    test "PUT /api/v1/lists/bubble → 403" do
      {:ok, resp} =
        Router.handle(%{
          method: "PUT",
          path: "/api/v1/lists/bubble",
          query: "",
          body: ~s({"title":"hijack"}),
          headers: [{"authorization", "Bearer t"}]
        })

      assert resp.status == 403
    end
  end

  defp restore(key, nil), do: Application.delete_env(:sukhi_api, key)
  defp restore(key, value), do: Application.put_env(:sukhi_api, key, value)
end
