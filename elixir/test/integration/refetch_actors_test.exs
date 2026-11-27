# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Integration.RefetchActorsTest do
  use SukhiFedi.IntegrationCase, async: false

  @moduletag :integration

  alias SukhiFedi.Maintenance.RefetchActors
  alias SukhiFedi.Schema.Account

  describe "remote_actor_uris/0" do
    test "lists remote actor URIs and excludes local accounts" do
      insert_account!(%Account{username: "local_ra", display_name: "local", summary: ""})

      remote =
        insert_account!(%Account{
          username: "remote_ra",
          display_name: "remote",
          summary: "",
          domain: "remote.example",
          actor_uri: "https://remote.example/users/remote_ra"
        })

      uris = RefetchActors.remote_actor_uris()

      assert remote.actor_uri in uris
      refute Enum.any?(uris, &is_nil/1)
      # the local row (domain nil, actor_uri nil) is not included
      refute "https://#{SukhiFedi.Config.domain!()}/users/local_ra" in uris
    end
  end
end
