# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Schema.PullStat do
  @moduledoc """
  Pull federation counters per time bucket.

  Read and written by table name (`from(x in "pull_stats")`, `Repo.insert_all("pull_stats", ..)`);
  this module is what gives hosigraph the types of its columns. The row's own key is the
  entity id; the table's old composite key is by convention, not enforced.
  """

  use Ecto.Schema

  @primary_key {:id, :id, autogenerate: true}
  schema "pull_stats" do
    field(:bucket, :naive_datetime_usec)
    field(:kind, :string)
    field(:n, :integer, default: 0)
    field(:sum_ms, :integer, default: 0)
    field(:max_ms, :integer, default: 0)
  end
end
