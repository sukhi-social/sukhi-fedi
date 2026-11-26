# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Schema.PullHost do
  @moduledoc """
  When to pull from a host next.

  Read and written by table name (`from(x in "pull_hosts")`, `Repo.insert_all("pull_hosts", ..)`);
  this module is what gives hosigraph the types of its columns. The row's own key is the
  entity id; the table's old composite key is by convention, not enforced.
  """

  use Ecto.Schema

  @primary_key {:id, :id, autogenerate: true}
  schema "pull_hosts" do
    field(:host, :string)
    field(:next_pull_at, :naive_datetime_usec)
    field(:failures, :integer, default: 0)
    field(:last_ok_at, :naive_datetime_usec)
    field(:last_error, :string)
  end
end
