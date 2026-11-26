# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Schema.PullPeerStat do
  @moduledoc """
  Counters per peer host and kind.

  Read and written by table name (`from(x in "pull_peer_stats")`, `Repo.insert_all("pull_peer_stats", ..)`);
  this module is what gives hosigraph the types of its columns. The row's own key is the
  entity id; the table's old composite key is by convention, not enforced.
  """

  use Ecto.Schema

  @primary_key {:id, :id, autogenerate: true}
  schema "pull_peer_stats" do
    field(:host, :string)
    field(:kind, :string)
    field(:n, :integer, default: 0)
    field(:last_at, :naive_datetime_usec)
  end
end
