# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiApi.Capabilities.AdminEmojisTest do
  use ExUnit.Case, async: false

  alias SukhiApi.Router

  # Records the call so a test can see exactly what the gateway was asked.
  defmodule FakeRpc do
    def call(mod, fun, args), do: call(mod, fun, args, 5_000)

    def call(SukhiFedi.CustomEmojis, :import_many, args, _t) do
      send(Application.get_env(:sukhi_api, :test_pid), {:import_many, args})

      case Application.get_env(:sukhi_api, :fake_import, :not_configured) do
        :not_configured -> {:error, :not_connected}
        reply -> {:ok, reply}
      end
    end

    # The router verifies the bearer through the same RPC door.
    def call(SukhiFedi.OAuth, fun, _args, _t) do
      case Map.fetch(Application.get_env(:sukhi_api, :fake_oauth, %{}), fun) do
        {:ok, reply} -> {:ok, reply}
        :error -> {:error, :not_connected}
      end
    end

    def call(_, _, _, _), do: {:error, :not_connected}
  end

  setup do
    prev = for k <- [:gateway_rpc_impl, :enabled_addons, :fake_oauth, :fake_import, :test_pid], into: %{}, do: {k, Application.get_env(:sukhi_api, k)}

    Application.put_env(:sukhi_api, :gateway_rpc_impl, FakeRpc)
    Application.put_env(:sukhi_api, :enabled_addons, :all)
    Application.put_env(:sukhi_api, :test_pid, self())
    Application.delete_env(:sukhi_api, :fake_import)

    on_exit(fn ->
      for {k, v} <- prev do
        if v == nil, do: Application.delete_env(:sukhi_api, k), else: Application.put_env(:sukhi_api, k, v)
      end
    end)

    :ok
  end

  defp account(admin?), do: %{id: 1, username: "root", is_admin: admin?}

  defp post(account, scopes, body, content_type \\ "application/json") do
    Application.put_env(:sukhi_api, :fake_oauth, %{
      verify_bearer: {:ok, %{account: account, app: %{id: 7, name: "t"}, scopes: scopes}}
    })

    Router.handle(%{
      method: "POST",
      path: "/api/admin/emojis",
      headers: [{"authorization", "Bearer t"}, {"content-type", content_type}],
      body: if(is_binary(body), do: body, else: JSON.encode!(body))
    })
  end

  defp summary do
    %{
      imported: 1,
      failed: 1,
      dry_run: false,
      results: [
        %{index: 0, shortcode: "blobcat", status: :ok, error: nil},
        %{index: 1, shortcode: nil, status: :error, error: :invalid_emoji_attributes}
      ]
    }
  end

  test "no token → 401" do
    {:ok, resp} = Router.handle(%{method: "POST", path: "/api/admin/emojis", headers: [], body: "{}"})
    assert resp.status == 401
  end

  test "a token without admin:write → 403 insufficient_scope" do
    {:ok, resp} = post(account(true), ["admin:read"], %{emojis: []})
    assert resp.status == 403
    assert JSON.decode!(resp.body)["error"] == "insufficient_scope"
  end

  test "admin:write but not an admin account → 403 admin_required, and the gateway is never asked" do
    {:ok, resp} = post(account(false), ["admin:write"], %{emojis: [%{shortcode: "a"}]})
    assert resp.status == 403
    assert JSON.decode!(resp.body)["error"] == "admin_required"
    refute_received {:import_many, _}
  end

  test "an admin's batch goes to the gateway with their id and renders per-item results" do
    Application.put_env(:sukhi_api, :fake_import, {:ok, summary()})
    items = [%{"shortcode" => "blobcat", "image_url" => "https://x/b.png"}, %{"nope" => 1}]

    {:ok, resp} = post(account(true), ["admin:write"], %{emojis: items})

    assert resp.status == 200
    assert_received {:import_many, [^items, 1, [dry_run: false]]}

    assert %{
             "imported" => 1,
             "failed" => 1,
             "dry_run" => false,
             "results" => [
               %{"index" => 0, "shortcode" => "blobcat", "status" => "ok"},
               %{"index" => 1, "status" => "error", "error" => "invalid_emoji_attributes"}
             ]
           } = JSON.decode!(resp.body)
  end

  test "dry_run is passed through" do
    Application.put_env(:sukhi_api, :fake_import, {:ok, %{summary() | dry_run: true, imported: 0}})
    {:ok, resp} = post(account(true), ["admin:write"], %{emojis: [%{shortcode: "a"}], dry_run: true})
    assert resp.status == 200
    assert_received {:import_many, [_, 1, [dry_run: true]]}
  end

  test "a body that is not {emojis: [...]} → 400, and the gateway is never asked" do
    for body <- [%{}, %{emojis: "x"}, %{emojis: %{a: 1}}, "not json"] do
      {:ok, resp} = post(account(true), ["admin:write"], body)
      assert resp.status == 400
      assert JSON.decode!(resp.body)["error"] == "emojis_required"
    end

    {:ok, resp} = post(account(true), ["admin:write"], "emojis=1", "application/x-www-form-urlencoded")
    assert resp.status == 400
    refute_received {:import_many, _}
  end

  test "the gateway's refusals map to 400 and 413" do
    Application.put_env(:sukhi_api, :fake_import, {:error, :empty})
    {:ok, resp} = post(account(true), ["admin:write"], %{emojis: []})
    assert resp.status == 400
    assert JSON.decode!(resp.body)["error"] == "emojis_empty"

    Application.put_env(:sukhi_api, :fake_import, {:error, :too_many})
    {:ok, resp} = post(account(true), ["admin:write"], %{emojis: [%{}]})
    assert resp.status == 413
    assert %{"error" => "too_many", "max" => 2000} = JSON.decode!(resp.body)
  end

  test "gateway down → 503" do
    {:ok, resp} = post(account(true), ["admin:write"], %{emojis: [%{shortcode: "a"}]})
    assert resp.status == 503
    assert JSON.decode!(resp.body)["error"] == "gateway_not_connected"
  end
end
