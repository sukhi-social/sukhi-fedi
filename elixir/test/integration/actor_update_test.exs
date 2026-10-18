# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Integration.ActorUpdateTest do
  @moduledoc """
  Inbound `Update(Person)` re-fetches the actor's shadow account — and
  only for a remote actor we already know, updating only itself.
  """

  use SukhiFedi.IntegrationCase, async: false

  @moduletag :integration

  alias SukhiFedi.AP.Instructions.ActorUpdate
  alias SukhiFedi.Repo
  alias SukhiFedi.Schema.Account

  @uri "https://remote.example/users/nuno"

  defp remote!(uri \\ @uri) do
    Repo.insert!(%Account{
      username: "nuno",
      display_name: "nuno",
      summary: "",
      domain: URI.parse(uri).host,
      actor_uri: uri,
      avatar_url: "https://remote.example/old.png"
    })
  end

  defp person(uri) do
    %{
      "id" => uri,
      "type" => "Person",
      "preferredUsername" => "nuno",
      "inbox" => uri <> "/inbox",
      "icon" => %{"type" => "Image", "url" => "https://remote.example/new.png"}
    }
  end

  defp update(actor, object_id) do
    %{
      "type" => "Update",
      "actor" => actor,
      "object" => %{"type" => "Person", "id" => object_id}
    }
  end

  defp fetch_ok(json), do: fn _uri -> {:ok, json} end

  test "Update(Person) re-fetches and refreshes the avatar" do
    acct = remote!()
    assert :ok = ActorUpdate.maybe_handle(update(@uri, @uri), fetch_ok(person(@uri)))
    assert %Account{avatar_url: "https://remote.example/new.png"} = Repo.get(Account, acct.id)
  end

  test "an object id that is not the actor is ignored" do
    acct = remote!()
    other = "https://remote.example/users/other"
    _ = remote!(other)

    test_pid = self()

    fetch = fn uri ->
      send(test_pid, {:fetched, uri})
      {:ok, person(uri)}
    end

    assert :ok = ActorUpdate.maybe_handle(update(@uri, other), fetch)
    refute_received {:fetched, _}
    assert %Account{avatar_url: "https://remote.example/old.png"} = Repo.get(Account, acct.id)
  end

  test "an actor we have no row for is not created" do
    assert :ok = ActorUpdate.maybe_handle(update(@uri, @uri), fetch_ok(person(@uri)))
    assert Repo.get_by(Account, actor_uri: @uri) == nil
  end

  test "a local actor is never re-fetched" do
    domain = SukhiFedi.Config.domain!()
    local = "https://#{domain}/users/someone"
    acct = remote!(local)
    test_pid = self()

    fetch = fn uri ->
      send(test_pid, {:fetched, uri})
      {:ok, person(uri)}
    end

    assert :ok = ActorUpdate.maybe_handle(update(local, local), fetch)
    refute_received {:fetched, _}
    assert %Account{avatar_url: "https://remote.example/old.png"} = Repo.get(Account, acct.id)
  end

  test "a document from another host does not overwrite the row" do
    acct = remote!()
    evil = person("https://evil.example/users/nuno")
    assert :ok = ActorUpdate.maybe_handle(update(@uri, @uri), fetch_ok(evil))
    assert %Account{avatar_url: "https://remote.example/old.png"} = Repo.get(Account, acct.id)
  end
end
