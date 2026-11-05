# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiApi.Capabilities.MastodonTranslationTest do
  use ExUnit.Case, async: false

  alias SukhiApi.Router

  @form "application/x-www-form-urlencoded"

  defmodule FakeRpc do
    def call(mod, fun, args), do: call(mod, fun, args, 5_000)

    def call(SukhiFedi.Translate, :status, args, timeout) do
      send(Application.get_env(:sukhi_api, :test_pid), {:translate, args, timeout})
      {:ok, Application.get_env(:sukhi_api, :fake_translate)}
    end

    def call(SukhiFedi.OAuth, fun, _args, _t) do
      case Map.fetch(Application.get_env(:sukhi_api, :fake_oauth, %{}), fun) do
        {:ok, reply} -> {:ok, reply}
        :error -> {:error, :not_connected}
      end
    end

    def call(_, _, _, _), do: {:error, :not_connected}
  end

  setup do
    keys = [:gateway_rpc_impl, :enabled_addons, :fake_oauth, :fake_translate, :test_pid]
    prev = for k <- keys, into: %{}, do: {k, Application.get_env(:sukhi_api, k)}

    Application.put_env(:sukhi_api, :gateway_rpc_impl, FakeRpc)
    Application.put_env(:sukhi_api, :enabled_addons, :all)
    Application.put_env(:sukhi_api, :test_pid, self())

    Application.put_env(:sukhi_api, :fake_oauth, %{
      verify_bearer: {:ok, %{account: %{id: 5, username: "reader"}, app: %{id: 1, name: "t"}, scopes: ["read:statuses"]}}
    })

    on_exit(fn ->
      for {k, v} <- prev do
        if v == nil, do: Application.delete_env(:sukhi_api, k), else: Application.put_env(:sukhi_api, k, v)
      end
    end)

    :ok
  end

  defp post(body, content_type, query) do
    Router.handle(%{
      method: "POST",
      path: "/api/v1/statuses/123/translate",
      query: query,
      headers: [{"authorization", "Bearer t"}, {"content-type", content_type}],
      body: body
    })
  end

  defp reply(result) do
    Application.put_env(:sukhi_api, :fake_translate, result)
    {:ok, %{status: status, body: body, headers: headers}} = post("lang=ja", @form, "")
    {status, JSON.decode!(body), Map.new(headers)}
  end

  test "asks the gateway for the viewer, the status and the language, with room for a slow engine" do
    Application.put_env(:sukhi_api, :fake_translate, {:ok, %{content: "<p>hi</p>", provider: "LibreTranslate"}})

    assert {:ok, %{status: 200, body: body}} = post("lang=ja", @form, "")
    assert %{"content" => "<p>hi</p>", "provider" => "LibreTranslate"} = JSON.decode!(body)
    assert_receive {:translate, [%{id: 5}, "123", "ja", [auto: false]], 30_000}
  end

  test "`lang` may come from JSON or the query string as well" do
    Application.put_env(:sukhi_api, :fake_translate, {:ok, %{content: "x"}})

    post(JSON.encode!(%{lang: "ko"}), "application/json", "")
    assert_receive {:translate, [_, "123", "ko", _], _}

    post("", "application/json", "lang=en")
    assert_receive {:translate, [_, "123", "en", _], _}
  end

  test "`auto` is true only for the literal true, and is handed on for the gateway to judge" do
    Application.put_env(:sukhi_api, :fake_translate, {:ok, %{content: "x"}})

    post("lang=ja&auto=true", @form, "")
    assert_receive {:translate, [_, "123", "ja", [auto: true]], _}

    post(JSON.encode!(%{lang: "ja", auto: true}), "application/json", "")
    assert_receive {:translate, [_, "123", "ja", [auto: true]], _}

    for odd <- ["1", "yes", "TRUE", ""] do
      post("lang=ja&auto=#{odd}", @form, "")
      assert_receive {:translate, [_, "123", "ja", [auto: false]], _}
    end
  end

  test "a refusal says what happened, in the status a client can act on" do
    assert {404, %{"error" => "not_found"}, _} = reply({:error, :not_found})
    assert {403, %{"error" => "not_translatable"}, _} = reply({:error, :not_translatable})
    assert {403, %{"error" => "auto_off"}, _} = reply({:error, :auto_off})
    assert {503, %{"error" => "translation_disabled"}, _} = reply({:error, :disabled})
    assert {422, %{"error" => "unsupported_language"}, _} = reply({:error, :unsupported_language})
    assert {422, %{"error" => "too_long"}, _} = reply({:error, :too_long})
    assert {422, %{"error" => "no_key"}, _} = reply({:error, :no_key})
    assert {422, %{"error" => "key_rejected"}, _} = reply({:error, :key_rejected})
    assert {422, %{"error" => "quota"}, _} = reply({:error, :quota})
    assert {503, %{"error" => "engine_unavailable"}, _} = reply({:error, :engine_unavailable})
    assert {503, %{"error" => "engine_unavailable"}, _} = reply({:error, :engine_rejected})
  end

  test "busy is a 429 that says how long to wait, in the header and the body" do
    assert {429, %{"error" => "busy", "retry_after" => 10}, %{"retry-after" => "10"}} = reply({:error, {:busy, 10}})
  end

  test "an unknown refusal is a plain 500, not a crash" do
    assert {500, %{"error" => "internal_error"}, _} = reply({:error, :something_new})
  end

  test "without a bearer token it is a 401" do
    assert {:ok, %{status: 401}} =
             Router.handle(%{method: "POST", path: "/api/v1/statuses/123/translate", headers: [], body: ""})
  end
end
