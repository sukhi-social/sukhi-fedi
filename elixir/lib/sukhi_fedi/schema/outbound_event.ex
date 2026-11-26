# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Schema.OutboundEvent do
  use Ecto.Schema
  use Ecto.Hosi.Schema
  import Ecto.Changeset

  @moduledoc """
  Index row over one archived outbound original. See the
  `CreateOutboundEvents` migration and `SukhiFedi.Federation.OutboundArchive`.
  The mirror of `SukhiFedi.Schema.InboundEvent`, keyed per delivery
  `(activity_id, inbox_url)` and carrying the remote's response status.
  """

  # the catalog's unique indexes, kept by the store
  hosi_unique([:activity_id, :inbox_url], name: "outbound_events_activity_id_inbox_url_index")

  schema "outbound_events" do
    field(:delivered_at, :utc_datetime_usec)
    field(:actor_uri, :string)
    field(:activity_id, :string)
    field(:inbox_url, :string)
    field(:status, :string)
    field(:response_status, :integer)
    field(:object_key, :string)
    field(:body_sha256, :string)

    timestamps(type: :utc_datetime, inserted_at: :created_at, updated_at: false)
  end

  @fields [
    :delivered_at,
    :actor_uri,
    :activity_id,
    :inbox_url,
    :status,
    :response_status,
    :object_key,
    :body_sha256
  ]

  def changeset(event, attrs) do
    event
    |> cast(attrs, @fields)
    |> validate_required([:delivered_at, :activity_id, :inbox_url, :object_key, :body_sha256])
  end
end
