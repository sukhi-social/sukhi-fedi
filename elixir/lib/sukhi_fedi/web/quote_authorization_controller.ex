# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Web.QuoteAuthorizationController do
  @moduledoc """
  Serves a FEP-044f `QuoteAuthorization` as AP JSON-LD.

  When a remote actor quotes one of our notes we grant a stamp
  (`AP.Instructions.Quotes`) and reply with an `Accept` whose `result`
  points here. The quoter embeds this URL as `quoteAuthorization`; their
  followers' servers dereference it to verify the quote was approved —
  authenticity comes from it being served under our own domain.

  `attributedTo` (the quoted note's author) and `interactionTarget` (the
  note's AP id) are derived from the stored `note_id`, never trusted from
  the request.
  """

  import Plug.Conn
  alias SukhiFedi.AP.ActorJson
  alias SukhiFedi.Notes.Ids
  alias SukhiFedi.{Accounts, Repo}
  alias SukhiFedi.Schema.{Account, Note, QuoteAuthorization}

  def show(conn, _opts) do
    username = conn.path_params["name"]
    id_raw = conn.path_params["id"]

    with {id, ""} <- Integer.parse(id_raw || ""),
         %Account{id: aid} <- SukhiFedi.Accounts.by_local_username(username),
         %QuoteAuthorization{state: "approved"} = auth <- Repo.get(QuoteAuthorization, id),
         %Note{} = note <- Note |> Repo.get(auth.note_id) |> preload_account(),
         true <- note.account_id == aid do
      send_json(conn, 200, to_ap(auth, note, username))
    else
      _ -> send_json(conn, 404, %{error: "not found"})
    end
  end

  defp to_ap(%QuoteAuthorization{} = auth, %Note{} = note, username) do
    actor_uri = ActorJson.actor_uri(username)

    %{
      "@context" => [
        "https://www.w3.org/ns/activitystreams",
        %{
          "QuoteAuthorization" => "https://w3id.org/fep/044f#QuoteAuthorization",
          "gts" => "https://gotosocial.org/ns#",
          "interactingObject" => %{"@id" => "gts:interactingObject", "@type" => "@id"},
          "interactionTarget" => %{"@id" => "gts:interactionTarget", "@type" => "@id"}
        }
      ],
      "type" => "QuoteAuthorization",
      "id" => "#{actor_uri}/quote-auth/#{auth.id}",
      "attributedTo" => actor_uri,
      # The quote post that was authorized, and our note it points at.
      "interactingObject" => auth.interacting_object_uri,
      "interactionTarget" => Ids.local_note_ap_id(note)
    }
  end

  defp preload_account(%Note{} = note), do: Repo.preload(note, account: &Accounts.by_ids/1)
  defp preload_account(other), do: other

  defp send_json(conn, status, body) do
    conn
    |> put_resp_content_type("application/activity+json")
    |> send_resp(status, JSON.encode!(body))
  end
end
