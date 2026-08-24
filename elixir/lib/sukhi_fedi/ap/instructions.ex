# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.AP.Instructions do
  @moduledoc """
  Parses and executes instructions returned by the Bun
  `fedify.inbox.v1` NATS Micro endpoint.

  This module is the dispatcher (and the trust boundary — see
  `execute/2`); the per-activity handling lives in the submodules:

    * `Instructions.Follows`   — Follow / Accept(Follow) / relay
      Accept+Reject / Undo(Follow)
    * `Instructions.Quotes`    — FEP-044f QuoteRequest (auto-approve →
      QuoteAuthorization) + Accept/Reject of our outbound request
    * `Instructions.DMs`       — non-public Create(Note) → conversations
    * `Instructions.Mirror`    — Create(Note) mirroring + Delete
    * `Instructions.Reactions` — Like / EmojiReact + their Undos
    * `Instructions.Boosts`    — Announce (notify + materialise) +
      Undo(Announce)
    * `Instructions.Pins`      — Add/Remove on a featured collection
    * `Instructions.Migrations`— Move (account migration: re-point follows)
    * `Instructions.Relayed`   — activity forwarded by a subscribed relay
      (re-fetched from its origin, never trusted inline)
    * `Instructions.Extract`   — pure AP JSON extractors
    * `Instructions.Resolve`   — actor/note resolution (shadow ingest)
  """

  alias SukhiFedi.AP.Instructions.{
    Boosts,
    DMs,
    Extract,
    Follows,
    Migrations,
    Mirror,
    Pins,
    Quotes,
    Reactions,
    Relayed
  }

  @doc """
  Executes an instruction map returned from the fedify.inbox.v1 endpoint.

  `signer_host` is the host of the HTTP-signature key's owner (from the
  inbox controller). The inline body of an activity is only trusted when
  the signer is the same host as the activity's `actor` — otherwise we are
  looking at a forwarded/relayed copy whose authority we can't verify, and
  only the handlers that re-resolve the actor and re-fetch the object
  independently (relayed `Announce` → boost materialisation, and
  `Instructions.Relayed` for a subscribed relay's forward) run. The
  arity-1 form (`:internal`) is the trusted entry used by archive replay
  and tests, which never flow through the inbox.

  `author_signed?` is the FEP-8b32 verdict from the same controller: the
  activity carried an Object Integrity Proof that verified against a key
  its own `actor` controls. That is the one fact about a *forwarded*
  body we can hold — the author vouched for these bytes, whoever carried
  them — so `Instructions.Relayed` can mirror a relayed post from the
  body instead of fetching it back from its origin.
  """
  @spec execute(map(), String.t() | :internal | nil, boolean()) :: :ok
  def execute(instruction, signer_host \\ :internal, author_signed? \\ false)

  def execute(%{"action" => "save", "object" => object_data}, signer_host, author_signed?) do
    if trusted_inline_origin?(object_data, signer_host) do
      DMs.maybe_handle_dm(object_data)
      Follows.maybe_handle_relay_reply(object_data)
      Follows.maybe_handle_follow_accept(object_data)
      Mirror.maybe_mirror_create_note(object_data)
      # FEP-044f: the quoted author accepted (or rejected) our outbound
      # QuoteRequest. Accept carries the stamp we echo on the note; Reject
      # means we must drop the quote.
      Quotes.maybe_handle_quote_accept(object_data)
      Quotes.maybe_handle_quote_reject(object_data)
      Reactions.maybe_handle_reaction(object_data)
      # A reblog notification should come from the booster's own server
      # (it delivers the Announce directly: signer == booster). We do not
      # fire it for a relay-forwarded copy.
      Boosts.maybe_notify_announce(object_data)
      Boosts.materialize_boost(object_data)
      Pins.maybe_handle_pin_unpin(object_data)
      Mirror.maybe_handle_delete(object_data)
      Mirror.maybe_handle_update(object_data)
      Migrations.maybe_handle_move(object_data)
      maybe_handle_undo(object_data)
    else
      # Forwarded/relayed: the signer is not the activity's actor. Only
      # materialise a relayed boost — `materialize_boost` re-resolves the
      # booster and re-fetches the note, and only acts when a local user
      # already follows the booster, so it can't be used to inject
      # arbitrary content or notifications.
      Boosts.materialize_boost(object_data)
      # And, when the signer is a relay we subscribe to, mirror the public
      # post it forwarded — again by re-fetching it from its own origin,
      # so the relay carries the notice and never the authority.
      Relayed.maybe_ingest(object_data, signer_host, author_signed?)
    end

    :ok
  end

  def execute(
        %{
          "action" => "save_and_reply",
          "save" => save_data,
          "reply" => reply,
          "inbox" => inbox_url
        },
        signer_host,
        _author_signed?
      ) do
    if trusted_inline_origin?(save_data["follow"], signer_host) do
      Follows.handle_accepted_follow(save_data, reply, inbox_url)
    end

    :ok
  end

  def execute(
        %{"action" => "quote_request", "quoteRequest" => quote_request, "inbox" => inbox_url},
        signer_host,
        _author_signed?
      ) do
    # Trust the inline request only from the requester's own server — the
    # `instrument` (their quote post) is theirs to assert. The target note
    # is resolved from our own DB, never from their claim.
    if trusted_inline_origin?(quote_request, signer_host) do
      Quotes.handle_quote_request(quote_request, inbox_url)
    end

    :ok
  end

  def execute(%{"action" => "ignore"}, _signer_host, _author_signed?) do
    :ok
  end

  defdelegate reingest_for_rebuild(activity), to: Mirror
  defdelegate materialize_boost(activity), to: Boosts

  # ── Private helpers ──────────────────────────────────────────────────────

  # The HTTP-signature owner must share the activity actor's host before we
  # trust the inline body. `:internal` (the arity-1 default) is the trusted
  # replay/test path. A nil or mismatched signer host is untrusted.
  defp trusted_inline_origin?(_data, :internal), do: true

  defp trusted_inline_origin?(data, signer_host)
       when is_map(data) and is_binary(signer_host) do
    case data |> Map.get("actor") |> Extract.extract_uri() do
      uri when is_binary(uri) ->
        case URI.parse(uri) do
          %URI{host: h} when is_binary(h) and h != "" ->
            String.downcase(h) == signer_host

          _ ->
            false
        end

      _ ->
        false
    end
  end

  defp trusted_inline_origin?(_data, _signer_host), do: false

  # Inbound `Undo`: reverse what the original activity materialised.
  # Routed to the module that owns the original: `Undo(Follow)` drops the
  # follow row; `Undo(Like)` / `Undo(EmojiReact)` drop the matching
  # `reactions` row; `Undo(Announce)` drops the `boosts` row so an
  # un-boost removes it from the home feed.
  defp maybe_handle_undo(%{"type" => "Undo", "actor" => actor_uri, "object" => inner})
       when is_binary(actor_uri) and is_map(inner) do
    case inner["type"] do
      "Follow" ->
        Follows.undo_follow(actor_uri, inner)

      type when type in ["Like", "EmojiReact"] ->
        Reactions.undo_reaction(actor_uri, inner)

      "Announce" ->
        Boosts.undo_announce(actor_uri, inner)

      _ ->
        :ok
    end
  end

  defp maybe_handle_undo(_), do: :ok
end
