# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiHosi.Source do
  @moduledoc """
  Where `Tail` reads sukhi's people and posts from. sukhi's `Repo` is Ecto over PostgreSQL or over
  Datalevin (`SUKHI_STORE`), so the reading is not written here in SQL: sukhi-fedi gives a module
  that reads through its `Repo`, and `SukhiHosi.Source.Postgres` is the one for a bare PostgreSQL
  (the tests, and a person running the copy by hand).

  A source is `{module, arg}`: every callback takes `arg` first (a connection, or nothing).

  Rows are maps with the columns of sukhi's tables as keys (`accounts`: `id username domain
  actor_uri`; `notes`: `id account_id ap_id content content_html visibility domain created_at
  in_reply_to_ap_id`, `created_at` a `DateTime`; `reactions`: `id account_id note_id`), in order of `id`.
  """

  @type account :: %{id: integer(), username: String.t(), domain: String.t() | nil, actor_uri: String.t() | nil}
  @type note :: %{
          id: integer(),
          account_id: integer(),
          ap_id: String.t() | nil,
          content: String.t() | nil,
          content_html: String.t() | nil,
          visibility: String.t(),
          domain: String.t() | nil,
          created_at: DateTime.t(),
          in_reply_to_ap_id: String.t() | nil
        }

  @type like :: %{id: integer(), account_id: integer(), note_id: integer()}

  @doc "The accounts with `id` above `after_id`, at most `limit`, oldest first."
  @callback accounts_after(arg :: term(), after_id :: integer(), limit :: pos_integer()) :: [account()]
  @doc "The notes with `id` above `after_id`, at most `limit`, oldest first."
  @callback notes_after(arg :: term(), after_id :: integer(), limit :: pos_integer()) :: [note()]
  @doc "The accounts with these ids (those that exist)."
  @callback accounts_by_ids(arg :: term(), ids :: [integer()]) :: [account()]
  @doc "The notes with these ids (those that exist)."
  @callback notes_by_ids(arg :: term(), ids :: [integer()]) :: [note()]
  @doc "The reactions that carry `emoji` with `id` above `after_id`, at most `limit`, oldest first."
  @callback likes_after(arg :: term(), after_id :: integer(), limit :: pos_integer(), emoji :: String.t()) :: [like()]
end
