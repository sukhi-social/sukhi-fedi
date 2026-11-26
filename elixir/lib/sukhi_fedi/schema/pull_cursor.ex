# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Schema.PullCursor do
  @moduledoc """
  Where we are in a remote actor's log.

  Read and written by table name (`from(x in "pull_cursors")`, `Repo.insert_all("pull_cursors", ..)`);
  this module is what gives hosigraph the types of its columns. The row's own key is the
  entity id; the table's old composite key is by convention, not enforced.
  """

  use Ecto.Schema

  @primary_key {:id, :id, autogenerate: true}
  schema "pull_cursors" do
    field(:actor_uri, :string)
    field(:host, :string)
    field(:seq, :integer)
    field(:updated_at, :naive_datetime_usec)
  end
end
