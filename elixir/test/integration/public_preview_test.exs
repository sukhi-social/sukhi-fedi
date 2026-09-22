# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Integration.PublicPreviewTest do
  @moduledoc """
  The logged-out HTML preview, through the real router pipeline:

    * an ActivityPub consumer (Accept: application/activity+json) still gets
      the actor / note JSON, regardless of the preview setting;
    * a crawler GET with PUBLIC_PREVIEW=meta gets OG / Twitter-card tags;
    * with PUBLIC_PREVIEW=off the same crawler GET is not a preview — it
      falls through to the SPA shell path.

  Visibility is honest: a followers-only note never renders here.
  """

  use SukhiFedi.IntegrationCase, async: false

  import Plug.Conn
  import Plug.Test

  @moduletag :integration

  alias SukhiFedi.Repo
  alias SukhiFedi.Schema.{Account, Note}
  alias SukhiFedi.Web.Router

  @opts Router.init([])

  setup do
    # Read at request time, so set per test and restore after.
    prev = Application.get_env(:sukhi_fedi, :public_preview, :off)
    on_exit(fn -> Application.put_env(:sukhi_fedi, :public_preview, prev) end)

    # `/@alice` `/@alice/123` は sukhi の SPA の道。natadeco の画面
    # (`/people/<id>`)へ案内するのは SSR の有るときだけなので、SSR_URL の
    # 無いここでは素通りする。

    n = System.unique_integer([:positive])
    account = create_account!("alice_#{n}")
    public = insert_note!(account.id, "hello public world", "public")

    %{account: account, public: public, n: n}
  end

  # ── helpers ────────────────────────────────────────────────────────────

  defp get(path, headers \\ []) do
    Enum.reduce(headers, conn(:get, path), fn {k, v}, c -> put_req_header(c, k, v) end)
    |> Router.call(@opts)
  end

  defp set_level(level), do: Application.put_env(:sukhi_fedi, :public_preview, level)

  defp content_type(conn), do: conn |> get_resp_header("content-type") |> List.first() || ""

  defp create_account!(username) do
    %Account{username: username, display_name: "Alice #{username}", summary: "<p>a bio</p>"}
    |> Repo.insert!()
  end

  defp insert_note!(account_id, content, visibility) do
    %Note{account_id: account_id, content: content, visibility: visibility}
    |> Repo.insert!()
  end

  # ── AP consumers are untouched ───────────────────────────────────────────

  test "AP Accept still gets actor JSON even with preview on", %{account: account} do
    set_level(:full)

    conn = get("/users/#{account.username}", [{"accept", "application/activity+json"}])

    assert conn.status == 200
    assert content_type(conn) =~ "application/activity+json"
    body = JSON.decode!(conn.resp_body)
    assert body["type"] == "Person"
    assert body["preferredUsername"] == account.username
    refute conn.resp_body =~ "og:title"
  end

  test "AP Accept still gets the note JSON even with preview on", %{account: account, public: note} do
    set_level(:full)

    conn =
      get("/users/#{account.username}/notes/#{note.id}", [{"accept", "application/activity+json"}])

    assert conn.status == 200
    assert content_type(conn) =~ "application/activity+json"
    assert JSON.decode!(conn.resp_body)["type"] == "Note"
  end

  # ── crawler GET, PUBLIC_PREVIEW=meta ─────────────────────────────────────

  test "crawler GET of a profile with meta gets OG tags but no body", %{account: account} do
    set_level(:meta)

    conn = get("/users/#{account.username}", [{"accept", "text/html"}])

    assert conn.status == 200
    assert content_type(conn) =~ "text/html"
    assert conn.resp_body =~ ~s(property="og:title")
    assert conn.resp_body =~ ~s(property="og:type" content="profile")
    assert conn.resp_body =~ "application/ld+json"
    assert conn.resp_body =~ account.username
    # meta level emits no post body
    refute conn.resp_body =~ ~s(class="post")
    # quiet by default: noindex
    assert conn.resp_body =~ ~s(name="robots" content="noindex)
    refute conn.resp_body =~ "<script src"
  end

  test "crawler GET of `/@alice` is the same profile preview", %{account: account} do
    set_level(:meta)

    conn = get("/@#{account.username}", [{"accept", "text/html"}])

    assert conn.status == 200
    assert conn.resp_body =~ ~s(property="og:type" content="profile")
  end

  test "crawler GET of a public note with full gets OG article + body", %{
    account: account,
    public: note
  } do
    set_level(:full)

    conn = get("/@#{account.username}/#{note.id}", [{"accept", "text/html"}])

    assert conn.status == 200
    assert conn.resp_body =~ ~s(property="og:type" content="article")
    assert conn.resp_body =~ "hello public world"
  end

  # ── off = SPA shell (not a preview) ──────────────────────────────────────

  test "with preview off a crawler GET is not a preview (falls through to SPA)",
       %{account: account} do
    set_level(:off)

    conn = get("/users/#{account.username}", [{"accept", "text/html"}])

    # Either way it is NOT the HTML preview: no OG tags.
    refute conn.resp_body =~ "og:title"
  end

  test "with preview off `/@alice` falls through to the SPA shell path", %{account: account} do
    set_level(:off)

    conn = get("/@#{account.username}", [{"accept", "text/html"}])

    refute conn.resp_body =~ "og:title"
  end

  # ── honesty: only public-visibility content renders ──────────────────────

  test "a followers-only note never renders in the preview", %{account: account} do
    set_level(:full)
    followers = insert_note!(account.id, "secret followers note", "followers")

    conn = get("/@#{account.username}/#{followers.id}", [{"accept", "text/html"}])

    assert conn.status == 404
    refute conn.resp_body =~ "secret followers note"
  end
end
