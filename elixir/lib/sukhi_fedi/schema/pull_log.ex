# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Schema.PullLog do
  @moduledoc """
  A local actor's pull log entry.

  Read and written by table name (`from(x in "pull_log")`, `Repo.insert_all("pull_log", ..)`);
  this module is what gives hosigraph the types of its columns. The row's own key is the
  entity id; the table's old composite key is by convention, not enforced.
  """

  use Ecto.Schema

  @primary_key {:id, :id, autogenerate: true}
  schema "pull_log" do
    field :account_id, :integer
    field :seq, :integer
    field :activity_id, :string
    field :body, :map
    field :inserted_at, :naive_datetime_usec, autogenerate: {NaiveDateTime, :utc_now, []}
  end
end
