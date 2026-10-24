# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Integration.NatsListenerDuplicateUsernameTest do
  @moduledoc """
  Remote accounts routinely share a username with a local one (`nyanrus`
  on three other servers). The listener must resolve the local author only,
  not blow up with `Ecto.MultipleResultsError`.
  """

  use SukhiFedi.IntegrationCase, async: false

  @moduletag :integration

  alias SukhiFedi.{LocalAccounts, Repo}
  alias SukhiFedi.Addons.Streaming.NatsListener
  alias SukhiFedi.Schema.{Account, Follow}

  defp remote!(username, domain) do
    %Account{}
    |> Account.changeset_remote(%{
      username: username,
      domain: domain,
      actor_uri: "https://#{domain}/users/#{username}"
    })
    |> Repo.insert!()
  end

  test "a status from a local author survives same-named remote accounts" do
    domain = SukhiFedi.Config.domain!()
    name = "dup#{System.unique_integer([:positive])}"

    {:ok, _} = LocalAccounts.create_admin(name, "long-enough-pass")
    remote!(name, "a.example")
    remote!(name, "b.example")

    author = SukhiFedi.Accounts.by_local_username(name)

    Repo.insert!(%Follow{
      follower_uri: "https://#{domain}/users/#{name}",
      followee_id: author.id,
      state: "accepted"
    })

    body = JSON.encode!(%{"object" => %{"id" => "x"}, "actor_id" => "https://#{domain}/users/#{name}"})

    assert {:noreply, _} =
             NatsListener.handle_info(
               {:msg, %{topic: "stream.new_post", body: body}},
               %{subscribed: true, gnat: nil}
             )
  end
end
