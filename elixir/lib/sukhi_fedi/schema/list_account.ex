# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Schema.ListAccount do
  @moduledoc """
  An account in a list.

  Read and written by table name (`from(x in "list_accounts")`, `Repo.insert_all("list_accounts", ..)`);
  this module is what gives hosigraph the types of its columns. The row's own key is the
  entity id; the table's old composite key is by convention, not enforced.
  """

  use Ecto.Schema

  @primary_key {:id, :id, autogenerate: true}
  schema "list_accounts" do
    field :list_id, :integer
    field :account_id, :integer
  end
end
