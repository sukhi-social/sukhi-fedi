# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Schema.PullPeer do
  @moduledoc """
  Notify state of a peer host.

  Read and written by table name (`from(x in "pull_peers")`, `Repo.insert_all("pull_peers", ..)`);
  this module is what gives hosigraph the types of its columns. The row's own key is the
  entity id; the table's old composite key is by convention, not enforced.
  """

  use Ecto.Schema

  @primary_key {:id, :id, autogenerate: true}
  schema "pull_peers" do
    field :host, :string
    field :notified_through, :integer, default: 0
    field :notified_at, :naive_datetime_usec
    field :failures, :integer, default: 0
    field :last_error, :string
  end
end
