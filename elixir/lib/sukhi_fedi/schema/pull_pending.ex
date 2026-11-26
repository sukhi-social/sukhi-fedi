# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Schema.PullPending do
  @moduledoc """
  A notified head not yet pulled.

  Read and written by table name (`from(x in "pull_pending")`, `Repo.insert_all("pull_pending", ..)`);
  this module is what gives hosigraph the types of its columns. The row's own key is the
  entity id; the table's old composite key is by convention, not enforced.
  """

  use Ecto.Schema

  @primary_key {:id, :id, autogenerate: true}
  schema "pull_pending" do
    field :host, :string
    field :actor_uri, :string
    field :head, :integer
    field :received_at, :naive_datetime_usec
  end
end
