# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiHosi.Source.Postgres do
  @moduledoc """
  `SukhiHosi.Source` over a bare PostgreSQL connection (`Postgrex`): sukhi's `accounts` and `notes`
  tables as they are. Used as `{SukhiHosi.Source.Postgres, conn}`.
  """

  @behaviour SukhiHosi.Source

  @impl true
  def accounts_after(conn, after_id, limit),
    do: q(conn, "SELECT id, username, domain, actor_uri FROM accounts WHERE id > $1 ORDER BY id LIMIT $2", [after_id, limit], &account/1)

  @impl true
  def accounts_by_ids(conn, ids),
    do: q(conn, "SELECT id, username, domain, actor_uri FROM accounts WHERE id = ANY($1) ORDER BY id", [ids], &account/1)

  @impl true
  def notes_after(conn, after_id, limit) do
    q(
      conn,
      """
      SELECT id, account_id, ap_id, content, content_html, visibility, domain, created_at, in_reply_to_ap_id
      FROM notes WHERE id > $1 ORDER BY id LIMIT $2
      """,
      [after_id, limit],
      fn [id, account_id, ap_id, content, content_html, visibility, domain, created_at, parent] ->
        %{id: id, account_id: account_id, ap_id: ap_id, content: content, content_html: content_html, visibility: visibility, domain: domain, created_at: created_at, in_reply_to_ap_id: parent}
      end
    )
  end

  defp account([id, username, domain, uri]), do: %{id: id, username: username, domain: domain, actor_uri: uri}

  defp q(conn, sql, args, row) do
    %{rows: rows} = Postgrex.query!(conn, sql, args)
    Enum.map(rows, row)
  end
end
