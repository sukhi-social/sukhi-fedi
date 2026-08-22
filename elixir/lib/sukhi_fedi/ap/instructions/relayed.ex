# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.AP.Instructions.Relayed do
  @moduledoc """
  Inbound activity forwarded by a relay we subscribe to.

  A relay's HTTP signature proves that *the relay* sent the bytes — never
  that the author wrote them. So a forwarded body is believed only when
  something else vouches for it:

    * **The author signed it** (FEP-8b32 Object Integrity Proof, checked
      at the inbox, its key bound to the activity's own `actor`). Then
      the body *is* the author's word and we mirror it as delivered —
      no fetch. Only fedify-family peers attach one today, so this is
      the fast path, not the common one.
    * **Otherwise** we take the object's `id` and fetch it from its own
      origin (`Federation.NoteFetcher.fetch_and_mirror/1`, a signed
      GET); the mirrored row is whatever that origin serves. Same shape
      as `Instructions.Boosts.materialize_boost/1`, and the same price —
      one GET per relayed activity. That is what not trusting the relay
      costs.

  A proof on an `Announce` vouches for the Announce, not for the note it
  points at, so that path always fetches.

  Only public `Create` and `Announce` are ingested, and only from a host
  we hold an accepted subscription with (`Relays.accepted_host?/1`).
  Relayed `Update` and `Delete` are dropped: an edit can be re-fetched on
  its own, but a deletion cannot be verified by fetching — a 404 is also
  what a briefly broken origin returns — so honouring one on a relay's
  word would hand every relay a delete button for other people's posts.

  Mirrored notes surface on the federated public timeline
  (`Timelines.public(local: false)`), which is where a relay's traffic
  belongs: visible when asked for, never in anyone's home feed.
  """

  alias SukhiFedi.Addons.Moderation
  alias SukhiFedi.AP.Instructions.{Extract, Mirror, Resolve}
  alias SukhiFedi.Federation.NoteFetcher
  alias SukhiFedi.Relays
  alias SukhiFedi.Schema.Note

  @typedoc """
  Which gate the activity stopped at. `:mirrored` — refetched from the
  origin; `:mirrored_signed` — taken from the body the author signed.
  """
  @type status ::
          :not_relayed
          | :unhandled
          | :not_public
          | :own_host
          | :blocked
          | :unresolved
          | :mirrored
          | :mirrored_signed

  @doc """
  Ingest `activity` if it arrived from an accepted relay. `signer_host`
  is the HTTP-signature key owner's host and `author_signed?` the
  FEP-8b32 verdict, both as computed by the inbox controller — the two
  things about a forwarded activity we have actually authenticated.

  Returns the gate it stopped at (the shape `Boosts.materialize_boost/1`
  uses) so a caller — or a test — can see *why* nothing was mirrored,
  and which of the two paths mirrored it.
  """
  @spec maybe_ingest(map(), term(), boolean()) :: status()
  def maybe_ingest(activity, signer_host, author_signed? \\ false)

  def maybe_ingest(activity, signer_host, author_signed?) when is_map(activity) do
    if Relays.accepted_host?(signer_host) do
      ingest(activity, author_signed?)
    else
      :not_relayed
    end
  end

  def maybe_ingest(_activity, _signer_host, _author_signed?), do: :not_relayed

  # ── Private ──────────────────────────────────────────────────────────────

  # Mastodon-style relays forward the author's own `Create` verbatim;
  # the audience may sit on the activity, the object, or both. Servers
  # differ on where they write it, so either saying "public" is enough.
  defp ingest(%{"type" => "Create", "object" => object} = activity, author_signed?) do
    uri = Extract.extract_object_id(object)

    cond do
      not (public?(object) or public?(activity)) -> :not_public
      author_signed? -> mirror_signed_body(activity, uri)
      true -> fetch_from_origin(uri)
    end
  end

  # Pleroma-style relays wrap the post in their own `Announce` of its
  # URI. The announced note is what we want — not a boost row credited
  # to the relay, which is not an account anyone here follows. A proof
  # here belongs to the Announce, so it buys nothing: still fetch.
  defp ingest(%{"type" => "Announce", "object" => object} = activity, _author_signed?) do
    if public?(activity) do
      fetch_from_origin(Extract.extract_object_id(object))
    else
      :not_public
    end
  end

  defp ingest(_activity, _author_signed?), do: :unhandled

  defp fetch_from_origin(uri) do
    case origin_gate(uri) do
      :open ->
        case NoteFetcher.fetch_and_mirror(uri) do
          {:ok, %Note{}} -> :mirrored
          # A relay firehose always carries some unreachable or already
          # deleted origins. A miss is ordinary, not an error.
          {:error, _reason} -> :unresolved
        end

      stopped ->
        stopped
    end
  end

  # The author signed this body, so it needs no round trip — hand it to
  # the same mirror the trusted path uses. `Mirror` re-checks that the
  # note id, its `attributedTo` and the activity's `actor` share a host,
  # which is what keeps a signed activity from carrying someone else's
  # post. `notify?: false`: a relay copy must never raise a mention
  # notification — a mention meant for a local user is delivered to
  # their inbox by the author's own server, and that copy takes the
  # trusted path.
  defp mirror_signed_body(activity, uri) do
    case origin_gate(uri) do
      :open ->
        Mirror.maybe_mirror_create_note(activity, false)

        # `maybe_mirror_create_note/2` answers `:ok` either way, so ask
        # the table whether the row actually landed.
        case Resolve.resolve_target_note(uri) do
          %Note{} -> :mirrored_signed
          nil -> :unresolved
        end

      stopped ->
        stopped
    end
  end

  # Which origins we will take a relayed object from at all.
  defp origin_gate(uri) when is_binary(uri) do
    host = uri |> Extract.actor_host() |> downcase()

    cond do
      is_nil(host) ->
        :unresolved

      # Our own post, bounced back by the relay. The real row is already
      # here (local notes carry no `ap_id`), so mirroring would duplicate
      # it — the boomerang that migration 20260612000003 had to clean up.
      Extract.own_host?(uri) ->
        :own_host

      # The inbox gate checked the *relay's* host, not the author's. A
      # suspended instance must not walk in through a relay.
      Moderation.instance_policy(host) == :reject ->
        :blocked

      true ->
        :open
    end
  end

  defp origin_gate(_uri), do: :unresolved

  # "Public" here means AS#Public in `to` — the same reading of an
  # audience every other inbound path uses. An unlisted post (public only
  # in `cc`) is not a relay's to carry, so it stops here.
  defp public?(map) when is_map(map), do: Extract.visibility_from(map) == "public"
  defp public?(_), do: false

  defp downcase(nil), do: nil
  defp downcase(s) when is_binary(s), do: String.downcase(s)
end
