# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Schema.OutboxEvent do
  @moduledoc """
  One row = one pending domain event waiting to be published to NATS.

  The `SukhiDelivery.Outbox.Relay` GenServer (on the delivery node)
  consumes rows where `status = "pending"` and flips them to
  `"published"` (or `"failed"` after exceeding attempts).
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "outbox" do
    field(:aggregate_type, :string)
    field(:aggregate_id, :string)
    field(:subject, :string)
    field(:payload, :map)
    field(:headers, :map, default: %{})
    field(:status, :string, default: "pending")
    field(:attempts, :integer, default: 0)
    field(:last_error, :string)
    field(:published_at, :utc_datetime_usec)

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @required [:aggregate_type, :aggregate_id, :subject, :payload]
  @optional [:headers, :status, :attempts, :last_error, :published_at]

  def changeset(event, attrs) do
    event
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_inclusion(:status, ["pending", "published", "failed"])
  end
end
