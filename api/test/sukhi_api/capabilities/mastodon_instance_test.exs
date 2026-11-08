# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiApi.Capabilities.MastodonInstanceTest do
  use ExUnit.Case, async: false

  alias SukhiApi.Router

  # Answers `Accounts.site_contact/0` from :fake_contact; the rest of the
  # instance document's gateway questions get "not connected" and fall back.
  defmodule FakeRpc do
    def call(mod, fun, args), do: call(mod, fun, args, 5_000)

    def call(SukhiFedi.Accounts, :site_contact, [], _t),
      do: {:ok, Application.get_env(:sukhi_api, :fake_contact)}

    def call(_, _, _, _), do: {:error, :not_connected}
  end

  defmodule Down do
    def call(_mod, _fun, _args, _t), do: {:error, :not_connected}
  end

  setup do
    prev =
      for k <- [:gateway_rpc_impl, :enabled_addons, :fake_contact],
          do: {k, Application.get_env(:sukhi_api, k)}

    Application.put_env(:sukhi_api, :gateway_rpc_impl, FakeRpc)
    Application.put_env(:sukhi_api, :enabled_addons, :all)

    on_exit(fn ->
      Enum.each(prev, fn
        {k, nil} -> Application.delete_env(:sukhi_api, k)
        {k, v} -> Application.put_env(:sukhi_api, k, v)
      end)
    end)
  end

  defp contact(attrs \\ %{}) do
    account =
      Map.merge(
        %{id: 7, username: "kuro", domain: nil, display_name: "くろ", is_admin: true},
        attrs
      )

    Application.put_env(:sukhi_api, :fake_contact, %{
      account: account,
      counts: %{followers: 3, following: 2, statuses: 9}
    })
  end

  defp get(path) do
    {:ok, resp} = Router.handle(%{method: "GET", path: path, headers: []})
    assert resp.status == 200
    JSON.decode!(resp.body)
  end

  test "v1 names the person who runs the server, as an account that wears the Admin badge" do
    contact()

    %{"contact_account" => acct} = get("/api/v1/instance")

    assert acct["acct"] == "kuro"
    assert acct["display_name"] == "くろ"
    assert acct["url"] == "https://localhost:4000/@kuro"
    assert acct["followers_count"] == 3
    assert [%{"name" => "Admin"}] = acct["roles"]
  end

  test "v2 carries the same person under contact.account" do
    contact()

    %{"contact" => %{"account" => acct}} = get("/api/v2/instance")

    assert acct["acct"] == "kuro"
    assert [%{"name" => "Admin"}] = acct["roles"]
  end

  test "nobody to name (or a gateway that cannot be asked) stays null, not an error" do
    Application.delete_env(:sukhi_api, :fake_contact)
    assert get("/api/v1/instance")["contact_account"] == nil
    assert get("/api/v2/instance")["contact"]["account"] == nil

    Application.put_env(:sukhi_api, :gateway_rpc_impl, Down)
    assert get("/api/v1/instance")["contact_account"] == nil
  end
end
