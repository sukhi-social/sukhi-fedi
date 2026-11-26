# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Schema.DeliveryReceipt do
  @moduledoc """
  A delivery attempt's outcome per activity and inbox.

  Read and written by table name (`from(x in "delivery_receipts")`, `Repo.insert_all("delivery_receipts", ..)`);
  this module is what gives hosigraph the types of its columns. The row's own key is the
  entity id; the table's old composite key is by convention, not enforced.
  """

  use Ecto.Schema

  @primary_key {:id, :id, autogenerate: true}
  schema "delivery_receipts" do
    field :activity_id, :string
    field :inbox_url, :string
    field :status, :string
    field :delivered_at, :naive_datetime_usec
    field :inserted_at, :naive_datetime_usec, autogenerate: {NaiveDateTime, :utc_now, []}
  end
end
