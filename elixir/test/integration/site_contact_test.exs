# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Integration.SiteContactTest do
  @moduledoc """
  Who the server names as its contact (`Accounts.site_contact/0`): the one
  place that decides it, so `/api/v1,v2/instance` only renders the answer.
  """

  use SukhiFedi.IntegrationCase, async: false

  @moduletag :integration

  alias SukhiFedi.{Accounts, HotCache}
  alias SukhiFedi.Schema.Account

  setup do
    HotCache.forget(:site_contact)
    prev = Application.get_env(:sukhi_fedi, :instance_contact)

    on_exit(fn ->
      HotCache.forget(:site_contact)

      case prev do
        nil -> Application.delete_env(:sukhi_fedi, :instance_contact)
        v -> Application.put_env(:sukhi_fedi, :instance_contact, v)
      end
    end)

    Application.delete_env(:sukhi_fedi, :instance_contact)
    :ok
  end

  defp person!(username, attrs \\ %{}) do
    struct!(Account, Map.merge(%{username: username, display_name: username, summary: ""}, attrs))
    |> Repo.insert!()
  end

  test "nobody is an admin: nobody is named" do
    person!("sc_plain")
    assert Accounts.site_contact() == nil
  end

  test "unset, it is the oldest local admin, with the counts the account view wants" do
    person!("sc_member")
    first = person!("sc_first_admin", %{is_admin: true})
    person!("sc_second_admin", %{is_admin: true})

    assert %{account: %Account{id: id}, counts: %{followers: 0}} = Accounts.site_contact()
    assert id == first.id
  end

  test "a remote account flagged admin is never the contact" do
    person!("sc_far", %{domain: "far.example", actor_uri: "https://far.example/users/sc_far", is_admin: true})
    assert Accounts.site_contact() == nil
  end

  test "INSTANCE_CONTACT names a local person, with or without the @" do
    person!("sc_boss", %{is_admin: true})
    chosen = person!("sc_chosen")

    Application.put_env(:sukhi_fedi, :instance_contact, "@sc_chosen")
    assert %{account: %Account{id: id}} = Accounts.site_contact()
    assert id == chosen.id
  end

  test "INSTANCE_CONTACT naming nobody here falls back to the admin" do
    boss = person!("sc_boss2", %{is_admin: true})

    Application.put_env(:sukhi_fedi, :instance_contact, "sc_nobody")
    assert %{account: %Account{id: id}} = Accounts.site_contact()
    assert id == boss.id
  end

  test "a closed account is not named" do
    person!("sc_gone", %{is_admin: true, deleted_at: DateTime.utc_now() |> DateTime.truncate(:second)})
    assert Accounts.site_contact() == nil
  end
end
