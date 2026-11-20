# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Repo do
  @moduledoc """
  The business data: Datalevin, through `SukhiFedi.Store.Adapter`. Job queues
  are not here; they are in PostgreSQL (`SukhiFedi.QueueRepo`).
  """

  use Ecto.Repo,
    otp_app: :sukhi_fedi,
    adapter: SukhiFedi.Store.Adapter
end
