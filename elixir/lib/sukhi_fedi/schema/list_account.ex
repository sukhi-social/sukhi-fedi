# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Schema.ListAccount do
  @moduledoc """
  An account in a list.

  Read and written by table name (`from(x in "list_accounts")`, `Repo.insert_all("list_accounts", ..)`);
  this module is what gives hosigraph the types of its columns. The row's own key is the
  entity id; the table's old composite key is by convention, not enforced.
  """

  use Ecto.Schema
  use Ecto.Hosi.Schema

  # the catalog's unique indexes, kept by the store
  hosi_unique([:list_id, :account_id], name: "list_accounts_list_id_account_id_index")

  @primary_key {:id, :id, autogenerate: true}
  # the catalog's foreign keys (ON DELETE) and write rules, kept by the adapter
  hosi_ref(:account_id, to: "accounts", on_delete: :cascade, name: "list_accounts_account_id_fkey")
  hosi_ref(:list_id, to: "lists", on_delete: :cascade, name: "list_accounts_list_id_fkey")

  schema "list_accounts" do
    field(:list_id, :integer)
    field(:account_id, :integer)
  end
end
