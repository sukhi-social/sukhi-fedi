# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.QueueRepo do
  @moduledoc """
  A SQLite file for the job queues, used only when the business data is in
  Datalevin (`SUKHI_STORE=datalevin`): Oban has no Datalevin engine, and its
  Lite engine wants an Ecto repo. See `SukhiFedi.Queue`.
  """

  use Ecto.Repo, otp_app: :sukhi_fedi, adapter: Ecto.Adapters.SQLite3
end
