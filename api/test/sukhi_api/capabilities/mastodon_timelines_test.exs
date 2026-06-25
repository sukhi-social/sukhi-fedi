# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiApi.Capabilities.MastodonTimelinesTest do
  use ExUnit.Case, async: false

  alias SukhiApi.Router

  defmodule FakeRpc do
    def call(mod, fun, args), do: call(mod, fun, args, 5_000)

    def call(SukhiFedi.Timelines, fun, args, _t), do: lookup(:fake_timelines, fun, args)
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
      tl: Application.get_env(:sukhi_api, :fake_timelines),
      oauth: Application.get_env(:sukhi_api, :fake_oauth)
    }

    Application.put_env(:sukhi_api, :gateway_rpc_impl, FakeRpc)
    Application.put_env(:sukhi_api, :enabled_addons, :all)
    Application.put_env(:sukhi_api, :fake_timelines, %{})

    on_exit(fn ->
      restore(:gateway_rpc_impl, prev.rpc)
      restore(:enabled_addons, prev.addons)
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

  defp authed_get(path, query) do
    Application.put_env(:sukhi_api, :fake_oauth, %{
      verify_bearer:
        {:ok, %{account: account(), app: %{id: 1, name: "x"}, scopes: ["read:statuses"]}}
    })

    %{
      method: "GET",
      path: path,
      query: query,
      headers: [{"authorization", "Bearer t"}]
    }
  end

  describe "GET /api/v1/timelines/home" do
    test "authenticated returns Status array + Link header" do
      Application.put_env(:sukhi_api, :fake_timelines, %{
        home: [note(3), note(2), note(1)]
      })

      {:ok, resp} = Router.handle(authed_get("/api/v1/timelines/home", "limit=3"))

      assert resp.status == 200
      body = JSON.decode!(resp.body)
      assert length(body) == 3
      assert hd(body)["id"] == "3"

      link =
        Enum.find_value(resp.headers, fn {k, v} ->
          if String.downcase(k) == "link", do: v
        end)

      assert link =~ ~s(rel="next")
      assert link =~ "max_id=1"
    end

    test "missing token → 401" do
      {:ok, resp} =
        Router.handle(%{
          method: "GET",
          path: "/api/v1/timelines/home",
          headers: []
        })

      assert resp.status == 401
    end
  end

  describe "GET /api/v1/timelines/public?local=true (local tab)" do
    test "local — unauthenticated, returns Status array" do
      Application.put_env(:sukhi_api, :fake_timelines, %{
        public: [note(2), note(1)]
      })

      {:ok, resp} =
        Router.handle(%{
          method: "GET",
          path: "/api/v1/timelines/public",
          query: "local=true",
          headers: []
        })

      assert resp.status == 200
      body = JSON.decode!(resp.body)
      assert length(body) == 2
      assert hd(body)["id"] == "2"
    end

    test "empty page → 200 with no Link header" do
      Application.put_env(:sukhi_api, :fake_timelines, %{public: []})

      {:ok, resp} =
        Router.handle(%{
          method: "GET",
          path: "/api/v1/timelines/public",
          query: "local=true",
          headers: []
        })

      assert resp.status == 200
      assert JSON.decode!(resp.body) == []
      refute Enum.any?(resp.headers, fn {k, _} -> String.downcase(k) == "link" end)
    end

    test "503 when gateway unreachable" do
      Application.delete_env(:sukhi_api, :fake_timelines)

      {:ok, resp} =
        Router.handle(%{
          method: "GET",
          path: "/api/v1/timelines/public",
          query: "local=true",
          headers: []
        })

      assert resp.status == 503
    end
  end

  describe "GET /api/v1/timelines/public (federated tab → ご近所 guide)" do
    test "no local param → a single guide post, no gateway call" do
      # No fake_timelines configured: the guide must not touch the gateway.
      Application.delete_env(:sukhi_api, :fake_timelines)

      {:ok, resp} =
        Router.handle(%{
          method: "GET",
          path: "/api/v1/timelines/public",
          headers: []
        })

      assert resp.status == 200
      body = JSON.decode!(resp.body)
      assert length(body) == 1
      status = hd(body)
      assert status["content"] =~ "ご近所"
      assert status["visibility"] == "public"
    end

    test "Korean reader (Accept-Language) → the guide speaks Korean" do
      {:ok, resp} =
        Router.handle(%{
          method: "GET",
          path: "/api/v1/timelines/public",
          headers: [{"accept-language", "ko-KR,ko;q=0.9"}]
        })

      assert resp.status == 200
      status = resp.body |> JSON.decode!() |> hd()
      assert status["content"] =~ "이웃"
      refute status["content"] =~ "ご近所"
    end

    test "paginating (max_id) → empty page so the guide doesn't repeat" do
      {:ok, resp} =
        Router.handle(%{
          method: "GET",
          path: "/api/v1/timelines/public",
          query: "max_id=9007199254740991",
          headers: []
        })

      assert resp.status == 200
      assert JSON.decode!(resp.body) == []
    end
  end

  defp restore(key, nil), do: Application.delete_env(:sukhi_api, key)
  defp restore(key, value), do: Application.put_env(:sukhi_api, key, value)
end
