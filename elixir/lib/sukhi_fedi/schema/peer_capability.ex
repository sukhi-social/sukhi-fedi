# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Schema.PeerCapability do
  @moduledoc """
  What a peer host offered (pull federation).

  Read and written by table name (`from(x in "peer_capabilities")`, `Repo.insert_all("peer_capabilities", ..)`);
  this module is what gives hosigraph the types of its columns. The row's own key is the
  entity id; the table's old composite key is by convention, not enforced.
  """

  use Ecto.Schema

  @primary_key {:id, :id, autogenerate: true}
  schema "peer_capabilities" do
    field(:host, :string)
    field(:hrefs, {:array, :string}, default: [])
    field(:seen_at, :naive_datetime_usec)
    field(:pull_notify, :string)
    field(:pull_stream, :string)
  end
end
