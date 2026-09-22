# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.AP.Instructions.DMs do
  @moduledoc """
  Inbound DMs: a `Create(Note)` addressed without AS#Public. Records
  conversation participants for inbox queries and mirrors the note,
  authored by the sender.
  """

  import Ecto.Query

  alias SukhiFedi.AP.Instructions.{Extract, Resolve}
  alias SukhiFedi.AP.{Emojis, MediaIngest, Published}
  alias SukhiFedi.Repo
  alias SukhiFedi.Schema.{Account, ConversationParticipant, Note}

  @doc """
  Detect incoming DMs: Create activity wrapping a Note whose `to` doesn't
  include the AS#Public URI. Record conversation participants for inbox queries.
  """
  def maybe_handle_dm(%{"type" => "Create", "object" => object, "actor" => actor_uri})
      when is_map(object) do
    to_list = Extract.normalize_collection(object["to"] || [])

    # A DM has no Public and no `/followers` audience. Followers-only is
    # NOT a DM — `Mirror` stores it with `visibility: "followers"` — so
    # gate on the same `direct` verdict instead of "non-public", which
    # also matched followers-only and sent it down this path for nothing.
    is_direct = Extract.visibility_from(object) == "direct"

    if is_direct do
      # A reply joins its parent's conversation first, so a thread stays
      # one conversation even when the origin omits a stable `context`
      # (Misskey-family servers do). Fall back to the AP thread id, then
      # to this note's own id as a brand-new thread's root.
      conversation_ap_id =
        dm_parent_conversation(Extract.extract_uri(object["inReplyTo"])) ||
          object["context"] || object["conversation"] || object["id"]

      domain = SukhiFedi.Config.domain!()
      local_recipients = Enum.filter(to_list, &String.contains?(&1, domain))

      # The note belongs to the sender, not the recipient. Resolve (and,
      # on first contact, ingest) the sender's account once: it authors
      # the stored note and joins the conversation so the recipient sees
      # who the DM is from.
      sender = resolve_dm_sender(object, actor_uri)

      record_sender_participant(conversation_ap_id, sender)
      Enum.each(local_recipients, &record_participant(conversation_ap_id, &1))

      # Persist only when a local account is actually addressed and the
      # note's id is on the sender's host (no spoofed ap_id). Idempotent on
      # the note's AP id, so re-delivery doesn't duplicate.
      if local_recipients != [] and Extract.same_host?(object["id"], actor_uri) do
        save_inbound_dm_note(object, sender, conversation_ap_id)
      end
    end
  end

  def maybe_handle_dm(_), do: :ok

  # Resolve the `conversation_ap_id` of the note an inbound DM replies to,
  # so the reply threads with it. A local parent synthesizes its AP id
  # (its `ap_id` column is NULL), so pull the note id out of our own
  # `/notes/<id>` URL and match on that; a remote parent matches on
  # `ap_id`. nil when there's no parent or we don't hold it.
  defp dm_parent_conversation(uri) when is_binary(uri) do
    query =
      case local_note_id(uri) do
        nil -> from(n in Note, where: n.ap_id == ^uri, select: n.conversation_ap_id)
        id -> from(n in Note, where: n.id == ^id, select: n.conversation_ap_id)
      end

    Repo.one(query)
  end

  defp dm_parent_conversation(_), do: nil

  # The numeric note id from one of our own synthesized note URLs
  # (`https://<domain>/users/<u>/notes/<id>`); nil for anything else.
  defp local_note_id(uri) do
    domain = SukhiFedi.Config.domain!()

    case Regex.run(~r{^https://#{Regex.escape(domain)}/users/[^/]+/notes/(\d+)$}, uri) do
      [_, id] -> String.to_integer(id)
      _ -> nil
    end
  end

  defp record_participant(conversation_ap_id, actor_uri) when is_binary(conversation_ap_id) do
    domain = SukhiFedi.Config.domain!()
    username = Extract.actor_username(actor_uri)

    account =
      if String.contains?(actor_uri, domain),
        do: SukhiFedi.Accounts.by_local_username(username),
        else: nil

    if account do
      # A received DM marks the local participant unread. Only local
      # accounts get a row (a remote sender has none); this path is the
      # remote→local receive, so the row being written is the recipient's.
      %ConversationParticipant{}
      |> ConversationParticipant.changeset(%{
        conversation_ap_id: conversation_ap_id,
        account_id: account.id,
        unread: true
      })
      |> Repo.insert(
        on_conflict: [set: [unread: true]],
        conflict_target: [:conversation_ap_id, :account_id]
      )
    end
  end

  defp record_participant(_, _), do: :ok

  # The sender authors the DM. `attributedTo` is the canonical author;
  # fall back to the Create's actor. Returns nil if we can't resolve or
  # ingest them — then the note and participant are skipped rather than
  # mis-attributed to the recipient.
  defp resolve_dm_sender(object, actor_uri) do
    uri = Extract.extract_uri(object["attributedTo"]) || actor_uri

    case uri && Resolve.resolve_or_ingest_actor(uri) do
      {:ok, %Account{} = account} -> account
      _ -> nil
    end
  end

  # The sender joins the conversation so it shows in the recipient's
  # `accounts` ("who is this from"). Their unread flag is irrelevant —
  # they don't read here — so it stays false.
  defp record_sender_participant(conversation_ap_id, %Account{id: account_id})
       when is_binary(conversation_ap_id) do
    %ConversationParticipant{}
    |> ConversationParticipant.changeset(%{
      conversation_ap_id: conversation_ap_id,
      account_id: account_id,
      unread: false
    })
    |> Repo.insert(
      on_conflict: [set: [unread: false]],
      conflict_target: [:conversation_ap_id, :account_id]
    )
  end

  defp record_sender_participant(_, _), do: :ok

  # Mirror the inbound DM into `notes`, authored by the sender. Keyed on
  # the note's AP id so threading resolves and re-delivery is a no-op.
  defp save_inbound_dm_note(object, %Account{id: account_id}, conversation_ap_id) do
    attrs = %{
      "account_id" => account_id,
      "content" => object["content"] || "",
      "ap_id" => object["id"],
      "visibility" => "direct",
      "cw" => Extract.content_warning(object),
      "sensitive" => object["sensitive"] == true,
      "emojis" => Emojis.from_tag(object["tag"]),
      "conversation_ap_id" => conversation_ap_id,
      "in_reply_to_ap_id" => Extract.extract_uri(object["inReplyTo"]),
      # A DM can carry Misskey MFM source and a quote target just like a public
      # note; the columns exist, so keep them rather than collapsing the DM to
      # rendered HTML only (mirror.ex does the same for public notes).
      "quote_of_ap_id" => Extract.extract_quote_uri(object),
      "mfm" => Extract.extract_mfm(object)
    }

    %Note{}
    |> Note.changeset(attrs)
    |> Published.stamp(object)
    |> Repo.insert(on_conflict: :nothing, conflict_target: :ap_id)
    |> tap(fn
      {:ok, %Note{id: nid}} when not is_nil(nid) ->
        MediaIngest.attach(nid, account_id, object["attachment"])

      _ ->
        :ok
    end)
  end

  defp save_inbound_dm_note(_, _, _), do: :ok
end
