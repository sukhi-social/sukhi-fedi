# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.AP.Instructions.Quotes do
  @moduledoc """
  FEP-044f quote approval.

  Inbound `QuoteRequest` — a remote actor quoting one of our public notes.
  We let anyone quote, with automatic approval (see
  `Fedi.Builders`' `interactionPolicy`), so we mint and persist a
  `QuoteAuthorization`, then deliver an `Accept` carrying its URI as
  `result` straight to the requester's inbox — the same direct-delivery
  shape as the Follow → Accept flow. A request for a note that isn't ours
  is ignored; for one of ours that isn't public, a `Reject`.

  Inbound `Accept` / `Reject` of *our own* outbound `QuoteRequest`: stamp
  the authorization onto our note so we can echo it (and serve it), or
  drop the quote because it was refused. These ride the generic `save`
  path (`AP.Instructions.execute/2`).
  """

  alias SukhiFedi.AP.Instructions.Extract
  alias SukhiFedi.AP.ActorJson
  alias SukhiFedi.Notes
  alias SukhiFedi.Notes.Ids
  alias SukhiFedi.Repo
  alias SukhiFedi.Schema.{Note, QuoteAuthorization}

  # Delivery runs on its own BEAM node with an Oban supervisor on the
  # :delivery queue; reach its worker by the fully-qualified string so the
  # gateway keeps no compile-time dependency on the delivery app. (Same as
  # `Instructions.Follows`.)
  @delivery_worker "SukhiDelivery.Delivery.Worker"
  @delivery_queue "delivery"

  # ── Inbound QuoteRequest → Accept(QuoteAuthorization) / Reject ───────────

  @doc """
  A remote actor asked to quote one of our notes. Auto-approve a public
  one (mint + persist the stamp, deliver `Accept`); `Reject` a non-public
  one; ignore anything that isn't ours.
  """
  def handle_quote_request(quote_request, inbox_url) when is_binary(inbox_url) do
    requester = Extract.extract_uri(quote_request["actor"])
    target_uri = Extract.extract_uri(quote_request["object"])
    quote_post_uri = Extract.extract_object_id(quote_request["instrument"])

    with true <- is_binary(requester) and is_binary(target_uri) and is_binary(quote_post_uri),
         note_id when is_integer(note_id) <- Ids.local_note_id_from_uri(target_uri),
         %Note{domain: nil} = note <- Note |> Repo.get(note_id) |> preload_account() do
      if note.visibility == "public" do
        approve(note, requester, quote_post_uri, quote_request, inbox_url)
      else
        deliver(reject_activity(note, quote_request), inbox_url)
      end
    else
      _ -> :ok
    end

    :ok
  end

  def handle_quote_request(_quote_request, _inbox_url), do: :ok

  defp approve(note, requester, quote_post_uri, quote_request, inbox_url) do
    case grant(note, requester, quote_post_uri) do
      {:ok, %QuoteAuthorization{} = auth} ->
        deliver(accept_activity(note, quote_request, auth_uri(note, auth)), inbox_url)

      {:error, _} ->
        :ok
    end
  end

  # One stamp per (note, quote post): a re-sent QuoteRequest reuses it
  # rather than minting a fresh URI. `returning: true` gives us the id
  # (existing or new) to build the authorization URL from.
  defp grant(%Note{id: note_id}, requester, quote_post_uri) do
    %QuoteAuthorization{}
    |> QuoteAuthorization.changeset(%{
      note_id: note_id,
      requester_actor_uri: requester,
      interacting_object_uri: quote_post_uri,
      state: "approved"
    })
    |> Repo.insert(
      on_conflict: {:replace, [:requester_actor_uri, :state]},
      conflict_target: [:note_id, :interacting_object_uri],
      returning: true
    )
  end

  # ── Inbound Accept / Reject of our outbound QuoteRequest ─────────────────

  @doc """
  The quoted author accepted our request: store the `QuoteAuthorization`
  URI on our note so we echo it on the note (and any re-fetch sees it).
  """
  def maybe_handle_quote_accept(%{
        "type" => "Accept",
        "object" => %{"type" => "QuoteRequest"} = inner
      } = activity) do
    with stamp when is_binary(stamp) <- Extract.extract_uri(activity["result"]),
         %Note{} = note <- our_quote_note(inner),
         {:ok, %Note{id: id}} <-
           note |> Ecto.Changeset.change(quote_authorization_ap_id: stamp) |> Repo.update() do
      # Re-deliver so followers' servers pick up the stamp and render the
      # quote inline rather than as a bare link.
      Notes.enqueue_update(id)
    end

    :ok
  end

  def maybe_handle_quote_accept(_), do: :ok

  @doc """
  The quoted author refused: drop the quote so we stop asserting it (the
  note keeps its body, just loses the reference).
  """
  def maybe_handle_quote_reject(%{
        "type" => "Reject",
        "object" => %{"type" => "QuoteRequest"} = inner
      }) do
    with %Note{} = note <- our_quote_note(inner),
         {:ok, %Note{id: id}} <-
           note
           |> Ecto.Changeset.change(quote_of_ap_id: nil, quote_authorization_ap_id: nil)
           |> Repo.update() do
      Notes.enqueue_update(id)
    end

    :ok
  end

  def maybe_handle_quote_reject(_), do: :ok

  # The `instrument` of an Accept/Reject echoes our quote post — one of
  # our own notes. Resolve it back to the local row.
  defp our_quote_note(inner) do
    with uri when is_binary(uri) <- Extract.extract_object_id(inner["instrument"]),
         note_id when is_integer(note_id) <- Ids.local_note_id_from_uri(uri) do
      Repo.get(Note, note_id)
    else
      _ -> nil
    end
  end

  # ── Activity builders (delivered with an HTTP signature, like Accept(Follow)) ──

  defp accept_activity(note, quote_request, result_uri) do
    base("Accept", note, quote_request)
    |> Map.put("result", result_uri)
  end

  defp reject_activity(note, quote_request) do
    base("Reject", note, quote_request)
  end

  defp base(type, %Note{account: account}, quote_request) do
    actor = ActorJson.actor_uri(account)

    %{
      "@context" => "https://www.w3.org/ns/activitystreams",
      "id" => activity_id(),
      "type" => type,
      "actor" => actor,
      "to" => Extract.extract_uri(quote_request["actor"]),
      # Echo the request with `instrument` flattened to its URI, the shape
      # FEP-044f's Accept/Reject example uses.
      "object" => %{
        "type" => "QuoteRequest",
        "id" => quote_request["id"],
        "actor" => Extract.extract_uri(quote_request["actor"]),
        "object" => Extract.extract_uri(quote_request["object"]),
        "instrument" => Extract.extract_object_id(quote_request["instrument"])
      }
    }
  end

  defp deliver(activity, inbox_url) do
    SukhiFedi.DeliveryQueue.insert!(
      Oban.Job.new(
        %{raw_json: activity, inbox_url: inbox_url, actor_uri: activity["actor"]},
        worker: @delivery_worker,
        queue: @delivery_queue
      )
    )

    :ok
  end

  defp auth_uri(%Note{account: account}, %QuoteAuthorization{id: id}) do
    "#{ActorJson.actor_uri(account)}/quote-auth/#{id}"
  end

  defp activity_id do
    "https://#{SukhiFedi.Config.domain!()}/activities/quote-auth/#{Ecto.UUID.generate()}"
  end

  defp preload_account(%Note{} = note), do: Repo.preload(note, :account)
  defp preload_account(other), do: other
end
