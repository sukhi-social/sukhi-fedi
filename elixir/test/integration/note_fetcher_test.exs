# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Integration.NoteFetcherTest do
  @moduledoc """
  `NoteFetcher.fetch_and_mirror/1` when the id it is handed names an
  *activity*: a group's FEP-1b12 `Announce{Create}` points at the Create,
  and mirroring that as a note would store an empty row under the
  activity's id.
  """

  use SukhiFedi.IntegrationCase, async: false

  @moduletag :integration

  import Plug.Conn

  alias SukhiFedi.Federation.NoteFetcher
  alias SukhiFedi.Repo
  alias SukhiFedi.Schema.Note

  setup do
    Application.put_env(:sukhi_shared, :disable_url_guard, true)
    on_exit(fn -> Application.delete_env(:sukhi_shared, :disable_url_guard) end)
    :ok
  end

  for type <- ["Create", "Announce", "Update", "Join"] do
    test "an id naming a #{type} is refused, and nothing is mirrored",
         %{mock_remote: bypass, mock_remote_url: base} do
      uri = base <> "/activities/#{unquote(type)}"
      serve(bypass, "/activities/#{unquote(type)}", %{"id" => uri, "type" => unquote(type)})

      assert {:error, {:not_a_note, unquote(type)}} = NoteFetcher.fetch_and_mirror(uri)
      assert Repo.get_by(Note, ap_id: uri) == nil
    end
  end

  test "a Note is not caught by the guard — it goes on to look for its author",
       %{mock_remote: bypass, mock_remote_url: base} do
    uri = base <> "/notes/1"
    serve(bypass, "/notes/1", %{"id" => uri, "type" => "Note", "content" => "hi"})

    assert {:error, :no_actor} = NoteFetcher.fetch_and_mirror(uri)
  end

  defp serve(bypass, path, document) do
    Bypass.stub(bypass, "GET", path, fn conn ->
      conn
      |> put_resp_content_type("application/activity+json")
      |> resp(200, JSON.encode!(document))
    end)
  end
end
