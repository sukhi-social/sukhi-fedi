# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Integration.QuoteFederationTest do
  @moduledoc """
  FEP-044f inbound quote approval: a remote actor quoting one of our
  notes sends a `QuoteRequest`; we auto-approve public notes (mint +
  persist a `QuoteAuthorization`, reply `Accept`), `Reject` non-public
  ones, and ignore requests for notes that aren't ours. The granted
  stamp is then dereferenceable.

      mix test --only integration
  """

  use SukhiFedi.IntegrationCase, async: false

  import Plug.Conn
  import Plug.Test
  import Ecto.Query

  @moduletag :integration

  alias SukhiFedi.{Config, Notes, Repo}
  alias SukhiFedi.AP.Instructions
  alias SukhiFedi.Schema.{Account, Note, QuoteAuthorization}
  alias SukhiFedi.Web.Router

  @opts Router.init([])
  @requester "https://remote.test/users/bob"
  @quote_post "https://remote.test/users/bob/notes/9"

  describe "inbound QuoteRequest" do
    test "a public note is auto-approved: stamp persisted + Accept enqueued" do
      author = create_account!("alice_qok")
      {:ok, note} = Notes.create_status(author, %{"status" => "quote me", "visibility" => "public"})

      run_quote_request(quote_request(author, note))

      auth = Repo.one!(from(q in QuoteAuthorization, where: q.note_id == ^note.id))
      assert auth.requester_actor_uri == @requester
      assert auth.interacting_object_uri == @quote_post
      assert auth.state == "approved"

      accept = delivered_activity()
      assert accept["type"] == "Accept"
      assert accept["actor"] == "https://#{Config.domain!()}/users/alice_qok"
      assert accept["result"] == "https://#{Config.domain!()}/users/alice_qok/quote-auth/#{auth.id}"
      assert accept["object"]["type"] == "QuoteRequest"
      assert accept["object"]["instrument"] == @quote_post
    end

    test "a re-sent request reuses the same stamp" do
      author = create_account!("alice_qdup")
      {:ok, note} = Notes.create_status(author, %{"status" => "again", "visibility" => "public"})

      run_quote_request(quote_request(author, note))
      run_quote_request(quote_request(author, note))

      assert [_one] = Repo.all(from(q in QuoteAuthorization, where: q.note_id == ^note.id))
    end

    test "a non-public note is rejected, no stamp" do
      author = create_account!("alice_qpriv")

      {:ok, note} =
        Notes.create_status(author, %{"status" => "followers only", "visibility" => "followers"})

      run_quote_request(quote_request(author, note))

      assert [] == Repo.all(from(q in QuoteAuthorization, where: q.note_id == ^note.id))
      assert delivered_activity()["type"] == "Reject"
    end

    test "a request for a note that isn't ours is ignored" do
      qr =
        quote_request_to("https://#{Config.domain!()}/users/ghost/notes/999999")

      run_quote_request(qr)

      assert [] == Repo.all(from(q in QuoteAuthorization))
      assert delivered_jobs() == []
    end
  end

  describe "inbound Accept / Reject of our QuoteRequest" do
    test "Accept stores the stamp and enqueues an Update re-delivery" do
      author = create_account!("alice_acc")
      note = insert_quote_note!(author, "https://remote.test/users/bob/notes/5")
      stamp = "https://remote.test/users/bob/quote-auth/1"

      :ok = Instructions.execute(%{"action" => "save", "object" => accept(author, note, stamp)})

      assert Repo.get(Note, note.id).quote_authorization_ap_id == stamp

      ev =
        Repo.one!(
          from(e in SukhiFedi.Schema.OutboxEvent,
            where:
              e.subject == "sns.outbox.note.updated" and e.aggregate_id == ^to_string(note.id)
          )
        )

      assert ev.payload["quote_authorization_ap_id"] == stamp
    end

    test "Reject drops the quote and enqueues an Update" do
      author = create_account!("alice_rej")
      note = insert_quote_note!(author, "https://remote.test/users/bob/notes/7")

      :ok = Instructions.execute(%{"action" => "save", "object" => reject(author, note)})

      assert Repo.get(Note, note.id).quote_of_ap_id == nil

      assert Repo.exists?(
               from(e in SukhiFedi.Schema.OutboxEvent,
                 where:
                   e.subject == "sns.outbox.note.updated" and
                     e.aggregate_id == ^to_string(note.id)
               )
             )
    end
  end

  describe "serving the QuoteAuthorization" do
    test "GET /users/:name/quote-auth/:id returns the AP object" do
      author = create_account!("alice_serve")
      {:ok, note} = Notes.create_status(author, %{"status" => "served", "visibility" => "public"})

      auth =
        Repo.insert!(%QuoteAuthorization{
          note_id: note.id,
          requester_actor_uri: @requester,
          interacting_object_uri: @quote_post,
          state: "approved"
        })

      conn =
        conn(:get, "/users/alice_serve/quote-auth/#{auth.id}")
        |> put_req_header("accept", "application/activity+json")
        |> Router.call(@opts)

      assert conn.status == 200
      body = JSON.decode!(conn.resp_body)
      assert body["type"] == "QuoteAuthorization"
      assert body["id"] == "https://#{Config.domain!()}/users/alice_serve/quote-auth/#{auth.id}"
      assert body["attributedTo"] == "https://#{Config.domain!()}/users/alice_serve"
      assert body["interactingObject"] == @quote_post
      assert body["interactionTarget"] == "https://#{Config.domain!()}/users/alice_serve/notes/#{note.id}"
    end

    test "an unknown id is 404" do
      conn =
        conn(:get, "/users/nobody/quote-auth/123456")
        |> Router.call(@opts)

      assert conn.status == 404
    end
  end

  # ── helpers ──────────────────────────────────────────────────────────────

  defp quote_request(%Account{} = author, note),
    do: quote_request_to(local_note_uri(author, note))

  defp quote_request_to(target_uri) do
    %{
      "@context" => "https://www.w3.org/ns/activitystreams",
      "id" => "https://remote.test/quotes/#{System.unique_integer([:positive])}",
      "type" => "QuoteRequest",
      "actor" => @requester,
      "object" => target_uri,
      "instrument" => @quote_post
    }
  end

  # Delivery runs on another BEAM node, so its Oban worker isn't loaded
  # here — drive the executor in :manual mode and inspect the enqueued job
  # instead of letting :inline run a missing worker.
  defp run_quote_request(qr) do
    Oban.Testing.with_testing_mode(:manual, fn ->
      assert :ok =
               Instructions.execute(
                 %{
                   "action" => "quote_request",
                   "quoteRequest" => qr,
                   "inbox" => "#{@requester}/inbox"
                 },
                 :internal
               )
    end)
  end

  defp delivered_jobs do
    SukhiFedi.Queue.repo().all(from(j in Oban.Job, where: j.worker == "SukhiDelivery.Delivery.Worker"))
  end

  defp delivered_activity do
    [job] = delivered_jobs()
    job.args["raw_json"]
  end

  # A local note that quotes a remote post (our outbound quote), awaiting
  # the author's Accept.
  defp insert_quote_note!(%Account{id: aid}, quoted_uri) do
    Repo.insert!(%Note{
      account_id: aid,
      content: "quoting remote",
      visibility: "public",
      quote_of_ap_id: quoted_uri,
      created_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
  end

  defp accept(author, note, stamp) do
    %{
      "type" => "Accept",
      "actor" => @requester,
      "object" => quote_request_echo(author, note),
      "result" => stamp
    }
  end

  defp reject(author, note) do
    %{"type" => "Reject", "actor" => @requester, "object" => quote_request_echo(author, note)}
  end

  defp quote_request_echo(author, note) do
    %{
      "type" => "QuoteRequest",
      "id" => "https://remote.test/quotes/echo",
      "actor" => @requester,
      "object" => note.quote_of_ap_id,
      "instrument" => local_note_uri(author, note)
    }
  end

  defp local_note_uri(%Account{username: u}, %{id: id}),
    do: "https://#{Config.domain!()}/users/#{u}/notes/#{id}"

  defp create_account!(username) do
    %Account{username: username, display_name: username, summary: ""}
    |> Repo.insert!()
  end
end
