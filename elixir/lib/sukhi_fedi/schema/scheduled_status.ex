# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Schema.ScheduledStatus do
  use Ecto.Schema
  use Ecto.Hosi.Schema
  import Ecto.Changeset

  # A status to publish later: the author's Mastodon-shaped create params
  # kept verbatim in `params`, a `scheduled_at` instant, and the id of the
  # Oban job that will publish it (so a cancel can delete that job). The
  # note's own validation happens when the worker replays `params` through
  # `create_status` — the same gate a live POST takes — so this changeset
  # only guards the envelope.
  # the catalog's foreign keys (ON DELETE) and write rules, kept by the adapter
  hosi_ref(:account_id, to: "accounts", on_delete: :cascade, name: "scheduled_statuses_account_id_fkey")

  schema "scheduled_statuses" do
    field(:account_id, :integer)
    field(:params, :map, default: %{})
    field(:scheduled_at, :utc_datetime)
    field(:oban_job_id, :integer)
    timestamps()
  end

  def changeset(scheduled, attrs) do
    scheduled
    |> cast(attrs, [:account_id, :params, :scheduled_at, :oban_job_id])
    |> validate_required([:account_id, :params, :scheduled_at])
  end
end
