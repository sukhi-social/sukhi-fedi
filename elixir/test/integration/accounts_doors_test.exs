# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Integration.AccountsDoorsTest do
  @moduledoc """
  The doors `SukhiFedi.Accounts` opens onto one account: by id, by actor URI,
  by handle, by monitored domain. They answer what the `Repo` call each one
  stands for answered, so a caller moved onto them sees no change.

      make test-pgrust ARGS="test/integration/accounts_doors_test.exs"
  """

  use SukhiFedi.IntegrationCase, async: false

  @moduletag :integration

  alias SukhiFedi.Accounts
  alias SukhiFedi.Schema.Account

  defp insert!(attrs), do: Repo.insert!(struct(Account, attrs))

  test "get/1 is the account or nil; get!/1 is the account or a raise" do
    a = insert!(username: "alice")

    assert %Account{username: "alice"} = got = Accounts.get(a.id)
    assert got.id == a.id
    assert Accounts.get(a.id + 1000) == nil

    assert %Account{username: "alice"} = Accounts.get!(a.id)
    assert_raise Ecto.NoResultsError, fn -> Accounts.get!(a.id + 1000) end
  end

  test "by_actor_uri/1 finds the account that stores that actor URI" do
    r = insert!(username: "bob", domain: "remote.test", actor_uri: "https://remote.test/users/bob")

    assert Accounts.by_actor_uri("https://remote.test/users/bob").id == r.id
    assert Accounts.by_actor_uri("https://remote.test/users/nobody") == nil
  end

  test "by_handle/2 is a name at a domain: the same name elsewhere is another account" do
    insert!(username: "bob")
    r = insert!(username: "bob", domain: "remote.test", actor_uri: "https://remote.test/users/bob")
    insert!(username: "bob", domain: "other.test", actor_uri: "https://other.test/users/bob")

    assert Accounts.by_handle("bob", "remote.test").id == r.id
    assert Accounts.by_handle("bob", "nowhere.test") == nil
    assert Accounts.by_handle("carol", "remote.test") == nil
  end

  test "by_monitored_domain/1 finds the monitor actor of that instance" do
    m = insert!(username: "watch-1", monitored_domain: "watched.test")
    insert!(username: "watch-2", monitored_domain: "other-watched.test")

    assert Accounts.by_monitored_domain("watched.test").id == m.id
    assert Accounts.by_monitored_domain("unwatched.test") == nil
  end
end
