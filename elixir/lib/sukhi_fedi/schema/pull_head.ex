# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Schema.PullHead do
  @moduledoc """
  The head of a local actor's pull log.

  Read and written by table name (`from(x in "pull_heads")`, `Repo.insert_all("pull_heads", ..)`);
  this module is what gives hosigraph the types of its columns. The row's own key is the
  entity id; the table's old composite key is by convention, not enforced.
  """

  use Ecto.Schema

  @primary_key {:id, :id, autogenerate: true}
  schema "pull_heads" do
    field(:account_id, :integer)
    field(:seq, :integer, default: 0)
    field(:pruned_through, :integer, default: 0)
  end
end
