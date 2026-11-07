# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiApi.Capabilities.JoinTest do
  use ExUnit.Case, async: false

  alias SukhiApi.Router

  # Answers from :fake_join and tells the test what the capability asked.
  defmodule FakeRpc do
    def call(mod, fun, args), do: call(mod, fun, args, 5_000)

    def call(SukhiFedi.JoinApplications, fun, args, _t) do
      send(Application.fetch_env!(:sukhi_api, :fake_join_pid), {:rpc, fun, args})
      table = Application.get_env(:sukhi_api, :fake_join, %{})
      {:ok, Map.fetch!(table, fun)}
    end

    def call(_, _, _, _), do: {:error, :not_connected}
  end

  defmodule Down do
    def call(_mod, _fun, _args, _t), do: {:error, :not_connected}
  end

  setup do
    prev =
      for k <- [:gateway_rpc_impl, :enabled_addons, :fake_join],
          do: {k, Application.get_env(:sukhi_api, k)}

    Application.put_env(:sukhi_api, :gateway_rpc_impl, FakeRpc)
    Application.put_env(:sukhi_api, :enabled_addons, :all)
    Application.put_env(:sukhi_api, :fake_join_pid, self())

    on_exit(fn ->
      Enum.each(prev, fn
        {k, nil} -> Application.delete_env(:sukhi_api, k)
        {k, v} -> Application.put_env(:sukhi_api, k, v)
      end)

      Application.delete_env(:sukhi_api, :fake_join_pid)
    end)
  end

  defp answer(table), do: Application.put_env(:sukhi_api, :fake_join, table)

  defp post(path, body) do
    Router.handle(%{
      method: "POST",
      path: path,
      headers: [{"content-type", "application/json"}],
      body: JSON.encode!(body)
    })
  end

  defp json({:ok, resp}), do: {resp.status, JSON.decode!(resp.body)}

  defp app(extra \\ %{}) do
    Map.merge(
      %{
        receipt: "482913",
        email: "yuki@example.test",
        call_name: "ゆき",
        found: "友だち",
        hope: "ゆっくり",
        check_on: ~D[2026-11-05],
        claim_hash: "h1",
        edit_hash: "h2"
      },
      extra
    )
  end

  test "GET info: who looks, which day" do
    answer(%{info: {:ok, %{greeter: "くろ", check_on: ~D[2026-11-05], weekday: 4, days_after: 3}}})

    {:ok, resp} =
      Router.handle(%{method: "GET", path: "/api/v1/join/info", headers: [], body: ""})

    assert resp.status == 200

    assert JSON.decode!(resp.body) == %{
             "greeter" => "くろ",
             "check_on" => "2026-11-05",
             "weekday" => 4,
             "days_after" => 3
           }
  end

  describe "POST /api/v1/join" do
    test "202 with the receipt and the claim; only the known fields go to the gateway; no hash comes back" do
      answer(%{submit: {:ok, %{application: app(), claim: "secret-claim", check: %{weekday: 4, days_after: 3}}}})

      assert {202, body} =
               json(
                 post("/api/v1/join", %{
                   "email" => "yuki@example.test",
                   "call_name" => "ゆき",
                   "found" => "友だち",
                   "hope" => "ゆっくり",
                   "lang" => "ja",
                   "receipt" => "000000",
                   "edit_hash" => "x"
                 })
               )

      assert body == %{
               "receipt" => "482913",
               "claim" => "secret-claim",
               "check_on" => "2026-11-05"
             }

      assert_received {:rpc, :submit, [attrs]}
      assert Map.keys(attrs) |> Enum.sort() == ~w(call_name email found hope lang)
    end

    test "validation errors are 422 with the field names" do
      cs = %Ecto.Changeset{errors: [email: {"is invalid", []}], valid?: false}
      answer(%{submit: {:error, cs}})

      assert {422, %{"error" => "validation_failed", "details" => %{"email" => "is invalid"}}} =
               json(post("/api/v1/join", %{"email" => "x"}))
    end

    test "rate limit and a mail that did not go are told apart" do
      answer(%{submit: {:error, :rate_limited}})
      assert {429, %{"error" => "rate_limited"}} = json(post("/api/v1/join", %{}))

      answer(%{submit: {:error, :send_failed}})
      assert {502, %{"error" => "send_failed"}} = json(post("/api/v1/join", %{}))
    end

    test "no gateway: 503" do
      Application.put_env(:sukhi_api, :gateway_rpc_impl, Down)
      assert {503, _} = json(post("/api/v1/join", %{"email" => "a@b.cc"}))
    end
  end

  describe "the claim and the key travel in the body" do
    test "received" do
      answer(%{received: {:ok, app()}})

      assert {200, %{"receipt" => "482913"}} =
               json(post("/api/v1/join/received", %{"claim" => "c"}))

      assert_received {:rpc, :received, ["c"]}

      answer(%{received: {:error, :not_found}})

      assert {404, %{"error" => "join_not_found"}} =
               json(post("/api/v1/join/received", %{"claim" => "c"}))

      # Not a string → never reaches the gateway as one.
      post("/api/v1/join/received", %{"claim" => 5})
      assert_received {:rpc, :received, [""]}
    end

    test "email" do
      answer(%{change_email: {:ok, app()}})

      assert {200, _} =
               json(post("/api/v1/join/email", %{"claim" => "c", "email" => "n@example.test"}))

      assert_received {:rpc, :change_email, ["c", "n@example.test"]}

      answer(%{change_email: {:error, :confirmed}})

      assert {409, %{"error" => "join_confirmed"}} =
               json(post("/api/v1/join/email", %{"claim" => "c", "email" => "n@example.test"}))
    end

    test "lookup shows the words, not the address or any hash" do
      answer(%{fetch_by_key: {:ok, app()}})
      assert {200, body} = json(post("/api/v1/join/lookup", %{"key" => "k"}))

      assert body == %{
               "receipt" => "482913",
               "call_name" => "ゆき",
               "found" => "友だち",
               "hope" => "ゆっくり",
               "check_on" => "2026-11-05"
             }

      answer(%{fetch_by_key: {:error, :not_found}})
      assert {404, _} = json(post("/api/v1/join/lookup", %{"key" => "k"}))
    end

    test "edit forwards the three words only" do
      answer(%{edit: {:ok, app()}})

      assert {200, _} =
               json(
                 post("/api/v1/join/edit", %{
                   "key" => "k",
                   "call_name" => "a",
                   "found" => "b",
                   "hope" => "c",
                   "email" => "evil@example.test"
                 })
               )

      assert_received {:rpc, :edit, ["k", words]}
      assert Map.keys(words) |> Enum.sort() == ~w(call_name found hope)
    end
  end
end
