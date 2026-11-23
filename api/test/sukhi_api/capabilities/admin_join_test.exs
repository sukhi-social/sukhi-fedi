# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiApi.Capabilities.AdminJoinTest do
  use ExUnit.Case, async: false

  alias SukhiApi.Router

  # Answers from :fake_join and tells the test what the capability asked.
  # The bearer is answered from :fake_oauth, the way admin_test.exs does.
  defmodule FakeRpc do
    def call(mod, fun, args), do: call(mod, fun, args, 5_000)

    def call(SukhiFedi.OAuth, :verify_bearer, _args, _t) do
      {:ok, Application.fetch_env!(:sukhi_api, :fake_bearer)}
    end

    def call(SukhiFedi.JoinApplications, fun, args, _t) do
      send(Application.fetch_env!(:sukhi_api, :fake_join_pid), {:rpc, fun, args})
      table = Application.get_env(:sukhi_api, :fake_join, %{})
      {:ok, Map.fetch!(table, fun)}
    end

    def call(_, _, _, _), do: {:error, :not_connected}
  end

  setup do
    keys = [:gateway_rpc_impl, :enabled_addons, :fake_join, :fake_bearer, :fake_join_pid]
    prev = for k <- keys, do: {k, Application.get_env(:sukhi_api, k)}

    Application.put_env(:sukhi_api, :gateway_rpc_impl, FakeRpc)
    Application.put_env(:sukhi_api, :enabled_addons, :all)
    Application.put_env(:sukhi_api, :fake_join_pid, self())

    on_exit(fn ->
      Enum.each(prev, fn
        {k, nil} -> Application.delete_env(:sukhi_api, k)
        {k, v} -> Application.put_env(:sukhi_api, k, v)
      end)
    end)
  end

  defp answer(table), do: Application.put_env(:sukhi_api, :fake_join, table)

  defp account(admin?), do: %{id: 9, username: "kuro", is_admin: admin?}

  # A request carrying a token with `scopes`, for `account`.
  defp call(method, path, scopes, account, body \\ nil) do
    Application.put_env(
      :sukhi_api,
      :fake_bearer,
      {:ok, %{account: account, app: %{id: 7, name: "test"}, scopes: scopes}}
    )

    Router.handle(%{
      method: method,
      path: path,
      headers: [{"authorization", "Bearer t"}, {"content-type", "application/json"}],
      body: if(body, do: JSON.encode!(body), else: "")
    })
  end

  defp json({:ok, resp}), do: {resp.status, JSON.decode!(resp.body)}

  # What the gateway holds, secrets included: nothing of this may leave.
  defp app(extra \\ %{}) do
    Map.merge(
      %{
        receipt: "482913",
        email: "yuki@example.test",
        call_name: "ゆき",
        found: "友だちが、ここの話をしていました。",
        hope: "夜に、ひとりで本を読んでいる人の話を、ゆっくり読みたいです。",
        lang: "ja",
        created_at: ~U[2026-11-22 05:00:00Z],
        check_on: ~D[2026-11-26],
        claim_hash: "claim-hash-secret",
        edit_hash: "edit-hash-secret",
        entry_hash: "entry-hash-secret"
      },
      extra
    )
  end

  @list "/api/admin/join_applications"

  describe "who may" do
    test "no token → 401" do
      {:ok, resp} = Router.handle(%{method: "GET", path: @list, headers: []})
      assert resp.status == 401
    end

    test "a token without the admin scope → 403 insufficient_scope" do
      assert {403, %{"error" => "insufficient_scope"}} =
               json(call("GET", @list, ["read:accounts"], account(true)))
    end

    test "a token that can only read cannot answer" do
      for action <- ["welcome", "decline"] do
        assert {403, %{"error" => "insufficient_scope"}} =
                 json(call("POST", "#{@list}/482913/#{action}", ["admin:read"], account(true), %{}))
      end

      refute_received {:rpc, _, _}
    end

    test "the right scope on an account that is not an admin → 403 admin_required, nothing asked" do
      assert {403, %{"error" => "admin_required"}} =
               json(call("GET", @list, ["admin:read"], account(false)))

      assert {403, %{"error" => "admin_required"}} =
               json(call("GET", "#{@list}/482913", ["admin:read"], account(false)))

      assert {403, %{"error" => "admin_required"}} =
               json(call("POST", "#{@list}/482913/welcome", ["admin:write"], account(false), %{}))

      assert {403, %{"error" => "admin_required"}} =
               json(call("POST", "#{@list}/482913/decline", ["admin:write"], account(false), %{}))

      refute_received {:rpc, :list_waiting, _}
      refute_received {:rpc, :fetch_waiting, _}
      refute_received {:rpc, :welcome, _}
      refute_received {:rpc, :decline, _}
    end
  end

  describe "GET list" do
    test "who is waiting and the next day; never an address, never a hash" do
      answer(%{
        list_waiting: [app(), app(%{receipt: "771204", call_name: nil, hope: nil, found: nil})],
        info: %{greeter: "くろ", check_on: ~D[2026-11-26], weekday: 4, days_after: 3}
      })

      {status, body} = json(call("GET", @list, ["admin:read"], account(true)))
      assert status == 200

      assert [first, second] = body["applications"]
      assert first["receipt"] == "482913"
      assert first["call_name"] == "ゆき"
      assert first["snippet"] =~ "夜に、ひとりで"
      assert second["snippet"] == nil

      assert body["next_check"] == %{
               "greeter" => "くろ",
               "check_on" => "2026-11-26",
               "weekday" => 4,
               "days_after" => 3
             }

      raw = JSON.encode!(body)
      refute raw =~ "yuki@example.test"
      refute raw =~ "hash"
      refute raw =~ "secret"
    end

    test "a long first answer is shortened in the list" do
      long = String.duplicate("あ", 200)
      answer(%{list_waiting: [app(%{hope: long})], info: %{greeter: nil, check_on: ~D[2026-11-26], weekday: 4, days_after: 3}})

      {200, body} = json(call("GET", @list, ["admin:read"], account(true)))
      [item] = body["applications"]
      assert String.length(item["snippet"]) == 61
      assert String.ends_with?(item["snippet"], "…")
    end
  end

  describe "GET one" do
    test "read in full, without the address or any hash" do
      answer(%{fetch_waiting: {:ok, app()}})

      {200, body} = json(call("GET", "#{@list}/482913", ["admin:read"], account(true)))

      assert body["receipt"] == "482913"
      assert body["found"] =~ "友だち"
      assert body["hope"] =~ "ゆっくり"
      assert_received {:rpc, :fetch_waiting, ["482913"]}

      raw = JSON.encode!(body)
      refute raw =~ "yuki@example.test"
      refute raw =~ "hash"
      refute raw =~ "secret"
    end

    test "unknown, or not waiting any more → 404" do
      answer(%{fetch_waiting: {:error, :not_found}})
      assert {404, %{"error" => "join_not_found"}} = json(call("GET", "#{@list}/000000", ["admin:read"], account(true)))
    end
  end

  describe "POST welcome" do
    test "asks the gateway with the receipt, the line as written, and who is asking" do
      answer(%{welcome: {:ok, app()}})

      assert {200, body} =
               json(
                 call("POST", "#{@list}/482913/welcome", ["admin:write"], account(true), %{
                   "note" => "夜の読書の話、すてきでした。"
                 })
               )

      assert body == %{"receipt" => "482913", "state" => "welcomed", "entry_valid_days" => 14}
      assert_received {:rpc, :welcome, ["482913", "夜の読書の話、すてきでした。", 9]}
      refute JSON.encode!(body) =~ "yuki@example.test"
    end

    test "no line is fine" do
      answer(%{welcome: {:ok, app()}})
      {200, _} = json(call("POST", "#{@list}/482913/welcome", ["admin:write"], account(true), %{}))
      assert_received {:rpc, :welcome, ["482913", nil, 9]}
    end

    test "the domain's no, each with its own status" do
      for {reason, status, error} <- [
            {:not_found, 404, "join_not_found"},
            {:send_failed, 502, "send_failed"},
            {:too_long, 422, "validation_failed"}
          ] do
        answer(%{welcome: {:error, reason}})

        assert {^status, %{"error" => ^error}} =
                 json(call("POST", "#{@list}/482913/welcome", ["admin:write"], account(true), %{}))
      end
    end
  end

  describe "POST decline" do
    test "asks the gateway with the reason as written, and who is asking" do
      answer(%{decline: :ok})

      assert {200, %{"receipt" => "482913", "state" => "declined"}} =
               json(
                 call("POST", "#{@list}/482913/decline", ["admin:write"], account(true), %{
                   "reason" => "今は、受けられる人数がいっぱいです。"
                 })
               )

      assert_received {:rpc, :decline, ["482913", "今は、受けられる人数がいっぱいです。", 9]}
    end

    test "the domain's no, each with its own status" do
      for {reason, status, error} <- [
            {:not_found, 404, "join_not_found"},
            {:send_failed, 502, "send_failed"},
            {:too_long, 422, "validation_failed"}
          ] do
        answer(%{decline: {:error, reason}})

        assert {^status, %{"error" => ^error}} =
                 json(call("POST", "#{@list}/482913/decline", ["admin:write"], account(true), %{}))
      end
    end
  end
end
