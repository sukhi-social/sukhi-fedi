# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Schema.AccountDeletion do
  @moduledoc """
  One request to close an account. Live while neither `cancelled_at` nor
  `finished_at` is set. See `SukhiFedi.AccountDeletion`.
  """
  use Ecto.Schema

  schema "account_deletions" do
    field(:account_id, :integer)
    field(:requested_at, :utc_datetime)
    field(:scheduled_for, :utc_datetime)
    field(:cancelled_at, :utc_datetime)
    field(:started_at, :utc_datetime)
    field(:finished_at, :utc_datetime)
  end
end
