# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Conversations do
  @moduledoc """
  Mastodon conversations (DM threads).

  A conversation is a `conversation_ap_id`: every DM Note carries one and
  every participant has a `conversation_participants` row. The Mastodon
  `id` of a conversation is per-account — here it's the viewer's own
  participant row id, so `POST /api/v1/conversations/:id/read` is a plain
  numeric id (no slashes from the AP URI) and maps straight to the row to
  clear.

  `list/2` returns the most-recent note per conversation the viewer is in,
  the *other* participants' accounts (the viewer excluded, Mastodon's
  "who else is in this thread"), and the viewer's `unread` flag.
  `fanout_entries/1` builds the same per-participant entry for every local
  participant of one conversation — the streaming `direct` producer.
  """

  import Ecto.Query

  alias SukhiFedi.Notes.Read
  alias SukhiFedi.Repo
  alias SukhiFedi.Schema.{Account, ConversationParticipant, Note}

  @default_limit 20
  @max_limit 40

  @spec list(integer(), keyword() | map()) :: [map()]
  def list(viewer_id, opts \\ []) when is_integer(viewer_id) do
    opts = normalize(opts)
    limit = clamp(opts[:limit])

    rows = viewer_rows(viewer_id)

    if rows == %{} do
      []
    else
      convo_ids = Map.keys(rows)
      last_notes = last_note_per_conversation(convo_ids, limit, opts, viewer_id)
      other_accounts = other_participants(convo_ids, viewer_id)

      Enum.map(last_notes, fn note ->
        cid = note.conversation_ap_id
        meta = Map.fetch!(rows, cid)

        %{
          id: meta.id,
          unread: meta.unread,
          accounts: Map.get(other_accounts, cid, []),
          last_status: note
        }
      end)
    end
  end

  @doc """
  The notes in one conversation, newest first. `conversation_id` is the
  participant row id from `list/2`, and the lookup is scoped to
  `viewer_id` — a client can't read someone else's thread.

  A DM thread is a queue on `conversation_ap_id`, so this reads it as one:
  a single query, no reply-chain walk. Notes that fell off the chain (a DM
  composed outside the thread, a root whose parent is gone) still belong to
  the conversation, so they still come back.
  """
  @spec statuses(integer(), integer() | String.t(), keyword() | map()) ::
          {:ok, [Note.t()]} | {:error, :not_found}
  def statuses(viewer_id, conversation_id, opts \\ []) when is_integer(viewer_id) do
    opts = normalize(opts)
    limit = clamp(opts[:limit])

    case viewer_conversation_ap_id(viewer_id, conversation_id) do
      nil ->
        {:error, :not_found}

      cid ->
        notes =
          from(n in Note, where: n.conversation_ap_id == ^cid)
          |> maybe_max_id(opts[:max_id])
          |> maybe_since_id(opts[:since_id])
          |> maybe_search(opts[:q])
          |> order_by([n], desc: n.id)
          |> limit(^limit)
          |> Repo.all()
          |> Repo.preload([:account, :media, :tags])
          |> Read.with_refs(viewer_id)

        {:ok, notes}
    end
  end

  @doc """
  Clear the unread flag on the viewer's conversation. `conversation_id`
  is the participant row id from `list/2`. Scoped to `viewer_id` so a
  client can't mark someone else's row read. Returns the refreshed entry
  (for the `200` body), or `{:error, :not_found}`.
  """
  @spec mark_read(integer(), integer() | String.t()) :: {:ok, map()} | {:error, :not_found}
  def mark_read(viewer_id, conversation_id) when is_integer(viewer_id) do
    id = to_int(conversation_id)

    {n, _} =
      from(cp in ConversationParticipant,
        where: cp.id == ^id and cp.account_id == ^viewer_id
      )
      |> Repo.update_all(set: [unread: false])

    case n do
      0 -> {:error, :not_found}
      _ -> {:ok, entry_for_row(viewer_id, id)}
    end
  end

  @doc """
  Per-participant conversation entries for one conversation — one for each
  *local* participant, from their own perspective (their row id + unread,
  the other participants as `accounts`). Used to fan a freshly-created DM
  out to each local participant's `direct` stream.
  """
  @spec fanout_entries(String.t()) :: [%{account_id: integer(), entry: map()}]
  def fanout_entries(conversation_ap_id) when is_binary(conversation_ap_id) do
    case latest_note(conversation_ap_id) do
      nil ->
        []

      note ->
        participants = participants_with_accounts(conversation_ap_id)

        participants
        |> Enum.filter(& &1.local?)
        |> Enum.map(fn me ->
          others =
            participants
            |> Enum.reject(&(&1.account_id == me.account_id))
            |> Enum.map(& &1.account)

          %{
            account_id: me.account_id,
            entry: %{
              id: me.id,
              unread: me.unread,
              accounts: others,
              # 参加者ごとに解決する。viewer で変わるのは自分の票の印だけなので、
              # 一人ぶんを使い回すと、他の人に「その人の票」が見えてしまう。
              last_status: Read.with_refs(note, me.account_id)
            }
          }
        end)
    end
  end

  # ── internals ──────────────────────────────────────────────────────────

  # The conversation behind one of the viewer's participant rows, or nil.
  # The `account_id` clause is the authorization — someone else's row simply
  # doesn't exist from here (CODE_STYLE §5).
  defp viewer_conversation_ap_id(viewer_id, conversation_id) do
    Repo.one(
      from cp in ConversationParticipant,
        where: cp.id == ^to_int(conversation_id) and cp.account_id == ^viewer_id,
        select: cp.conversation_ap_id
    )
  end

  # The viewer's participant rows keyed by conversation: `%{cid => %{id, unread}}`.
  defp viewer_rows(viewer_id) do
    Repo.all(
      from cp in ConversationParticipant,
        where: cp.account_id == ^viewer_id,
        select: {cp.conversation_ap_id, %{id: cp.id, unread: cp.unread}}
    )
    |> Map.new()
  end

  defp entry_for_row(viewer_id, cp_id) do
    cp = Repo.get!(ConversationParticipant, cp_id)
    note = latest_note(cp.conversation_ap_id)

    others =
      cp.conversation_ap_id
      |> participants_with_accounts()
      |> Enum.reject(&(&1.account_id == viewer_id))
      |> Enum.map(& &1.account)

    %{id: cp.id, unread: cp.unread, accounts: others, last_status: Read.with_refs(note, viewer_id)}
  end

  defp last_note_per_conversation(convo_ids, limit, opts, viewer_id) do
    # Take the newest note per conversation_ap_id, then page by note id.
    sub =
      from n in Note,
        where: n.conversation_ap_id in ^convo_ids,
        group_by: n.conversation_ap_id,
        select: %{cid: n.conversation_ap_id, max_id: max(n.id)}

    base =
      from n in Note,
        join: m in subquery(sub),
        on: m.max_id == n.id

    base
    |> maybe_max_id(opts[:max_id])
    |> maybe_since_id(opts[:since_id])
    |> order_by([n], desc: n.id)
    |> limit(^limit)
    |> Repo.all()
    |> Repo.preload([:account, :media, :tags])
    # `last_status` は Mastodon の契約では完全な Status。`with_refs/2` を
    # 通さないと in_reply_to_id / 引用 / 投票が落ちたまま互換クライアントへ
    # 出ていく(単体の GET /api/v1/statuses/:id は通しているので、同じ note が
    # 口によって違う形で見える)。viewer は自分の票の印にだけ効く。
    |> Read.with_refs(viewer_id)
  end

  defp latest_note(conversation_ap_id) do
    from(n in Note,
      where: n.conversation_ap_id == ^conversation_ap_id,
      order_by: [desc: n.id],
      limit: 1
    )
    |> Repo.one()
    |> case do
      nil -> nil
      note -> Repo.preload(note, [:account, :media, :tags])
    end
  end

  defp other_participants(convo_ids, viewer_id) do
    rows =
      Repo.all(
        from cp in ConversationParticipant,
          join: a in Account,
          on: a.id == cp.account_id,
          where: cp.conversation_ap_id in ^convo_ids and cp.account_id != ^viewer_id,
          select: %{
            cid: cp.conversation_ap_id,
            account: %{
              id: a.id,
              username: a.username,
              display_name: a.display_name,
              summary: a.summary,
              domain: a.domain,
              actor_uri: a.actor_uri,
              avatar_url: a.avatar_url,
              banner_url: a.banner_url
            }
          }
      )

    Enum.group_by(rows, & &1.cid, & &1.account)
  end

  # Every participant of one conversation, with account info and a
  # local? flag. Drives `fanout_entries/1` and the per-row `accounts`.
  defp participants_with_accounts(conversation_ap_id) do
    Repo.all(
      from cp in ConversationParticipant,
        join: a in Account,
        on: a.id == cp.account_id,
        where: cp.conversation_ap_id == ^conversation_ap_id,
        select: %{
          id: cp.id,
          account_id: cp.account_id,
          unread: cp.unread,
          local?: is_nil(a.domain),
          account: %{
            id: a.id,
            username: a.username,
            display_name: a.display_name,
            summary: a.summary,
            domain: a.domain,
            actor_uri: a.actor_uri,
            avatar_url: a.avatar_url,
            banner_url: a.banner_url
          }
        }
    )
  end

  defp maybe_max_id(q, nil), do: q
  defp maybe_max_id(q, v), do: where(q, [n], n.id < ^to_int(v))

  defp maybe_since_id(q, nil), do: q
  defp maybe_since_id(q, v), do: where(q, [n], n.id > ^to_int(v))

  # Clips の「全文検索」。件数の小さい単一会話が相手なので、GIN index も
  # 形態素解析も要らない ── ILIKE の部分一致で足りる(サイト全体の全文検索は
  # 別問題、OPEN_QUESTIONS.md#Q1 で検討中)。ユーザの入力に `%` / `_` が
  # 混じっていても ILIKE のワイルドカードとして暴発しないよう先にエスケープ
  # する(「100%」を検索しても、それが「1000000...」に化けたりしない)。
  defp maybe_search(q, nil), do: q
  defp maybe_search(q, ""), do: q

  defp maybe_search(q, term) when is_binary(term) do
    escaped = term |> String.replace("\\", "\\\\") |> String.replace("%", "\\%") |> String.replace("_", "\\_")
    where(q, [n], ilike(n.content, ^"%#{escaped}%"))
  end

  defp to_int(v), do: SukhiFedi.Coercion.to_int!(v)

  defp clamp(n) when is_integer(n) and n > 0 and n <= @max_limit, do: n
  defp clamp(_), do: @default_limit

  defp normalize(opts) when is_list(opts), do: Map.new(opts)
  defp normalize(opts) when is_map(opts), do: opts
end
