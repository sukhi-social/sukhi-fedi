# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Integration.NodeinfoCountsTest do
  use SukhiFedi.IntegrationCase, async: false

  @moduletag :integration

  alias SukhiFedi.Schema.{Account, Note}
  alias SukhiFedi.Web.NodeinfoController

  test "local accounts and posts are counted, remote ones are not" do
    ada = insert_account!(%Account{username: "ni_ada"})
    insert_account!(%Account{username: "ni_far", domain: "remote.example"})
    SukhiFedi.Repo.insert!(%Note{account_id: ada.id, content: "hi", visibility: "public"})

    conn = NodeinfoController.v2_1(Plug.Test.conn(:get, "/nodeinfo/2.1"), [])

    assert %{"users" => %{"total" => 1}, "localPosts" => 1} = JSON.decode!(conn.resp_body)["usage"]
  end
end
