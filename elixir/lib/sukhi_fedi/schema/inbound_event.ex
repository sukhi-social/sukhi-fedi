# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Schema.InboundEvent do
  use Ecto.Schema
  use Ecto.Hosi.Schema
  import Ecto.Changeset

  @moduledoc """
  Index row over one archived inbound original. See the
  `CreateInboundEvents` migration and `SukhiFedi.Federation.InboundArchive`.
  """

  # the catalog's unique indexes, kept by the store
  hosi_unique(:body_sha256)

  schema "inbound_events" do
    field(:received_at, :utc_datetime_usec)
    field(:actor_uri, :string)
    field(:activity_type, :string)
    field(:activity_id, :string)
    field(:object_key, :string)
    field(:body_sha256, :string)
    field(:inbox, :string)

    timestamps(type: :utc_datetime, inserted_at: :created_at, updated_at: false)
  end

  @fields [
    :received_at,
    :actor_uri,
    :activity_type,
    :activity_id,
    :object_key,
    :body_sha256,
    :inbox
  ]

  def changeset(event, attrs) do
    event
    |> cast(attrs, @fields)
    |> validate_required([:received_at, :object_key, :body_sha256])
  end
end
