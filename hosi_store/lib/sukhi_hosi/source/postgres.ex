# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiHosi.Source.Postgres do
  @moduledoc """
  `SukhiHosi.Source` over a bare PostgreSQL connection (`Postgrex`): sukhi's `accounts`, `notes` and
  `reactions` tables as they are. Used as `{SukhiHosi.Source.Postgres, conn}`.
  """

  @behaviour SukhiHosi.Source

  @note "id, account_id, ap_id, content, content_html, visibility, domain, created_at, in_reply_to_ap_id"

  @impl true
  def accounts_after(conn, after_id, limit),
    do: q(conn, "SELECT id, username, domain, actor_uri FROM accounts WHERE id > $1 ORDER BY id LIMIT $2", [after_id, limit], &account/1)

  @impl true
  def accounts_by_ids(conn, ids),
    do: q(conn, "SELECT id, username, domain, actor_uri FROM accounts WHERE id = ANY($1) ORDER BY id", [ids], &account/1)

  @impl true
  def notes_after(conn, after_id, limit),
    do: q(conn, "SELECT #{@note} FROM notes WHERE id > $1 ORDER BY id LIMIT $2", [after_id, limit], &note/1)

  @impl true
  def notes_by_ids(conn, ids),
    do: q(conn, "SELECT #{@note} FROM notes WHERE id = ANY($1) ORDER BY id", [ids], &note/1)

  @impl true
  def notes_by_ap_ids(conn, ap_ids),
    do: q(conn, "SELECT #{@note} FROM notes WHERE ap_id = ANY($1) ORDER BY id", [ap_ids], &note/1)

  @impl true
  def likes_of_notes(conn, note_ids, emoji) do
    q(
      conn,
      "SELECT id, account_id, note_id FROM reactions WHERE note_id = ANY($1) AND emoji = $2 ORDER BY id",
      [note_ids, emoji],
      fn [id, account_id, note_id] -> %{id: id, account_id: account_id, note_id: note_id} end
    )
  end

  @impl true
  def likes_after(conn, after_id, limit, emoji) do
    q(
      conn,
      "SELECT id, account_id, note_id FROM reactions WHERE id > $1 AND emoji = $2 ORDER BY id LIMIT $3",
      [after_id, emoji, limit],
      fn [id, account_id, note_id] -> %{id: id, account_id: account_id, note_id: note_id} end
    )
  end

  defp note([id, account_id, ap_id, content, content_html, visibility, domain, created_at, parent]) do
    %{id: id, account_id: account_id, ap_id: ap_id, content: content, content_html: content_html, visibility: visibility, domain: domain, created_at: created_at, in_reply_to_ap_id: parent}
  end

  defp account([id, username, domain, uri]), do: %{id: id, username: username, domain: domain, actor_uri: uri}

  defp q(conn, sql, args, row) do
    %{rows: rows} = Postgrex.query!(conn, sql, args)
    Enum.map(rows, row)
  end
end
