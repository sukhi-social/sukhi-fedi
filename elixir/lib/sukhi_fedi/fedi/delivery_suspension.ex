# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Fedi.DeliverySuspension do
  @moduledoc """
  FEP-f799 on the gateway side (docs/DELIVERY_SUSPENSION.md): what to start,
  and the parts that are started.

    * `Receiver` — takes in a notice and its cancellation;
    * `Store` — remembers them (PostgreSQL, `SukhiFedi.AccountRepo`);
    * `Upkeep` — fills the delivery worker's ETS copy
      (`SukhiShared.DeliverySuspension.Cache`) from the store when the gateway
      starts, and forgets the old once an hour.

  On unless `config :sukhi_fedi, :delivery_suspension, false` (the unit tests,
  which have no database): then nothing here starts, the cache has no table,
  and no delivery is ever held.
  """

  @doc "Is FEP-f799 handled? Read where it matters: the inbox, the hint job, the children."
  @spec enabled?() :: boolean()
  def enabled?, do: Application.get_env(:sukhi_fedi, :delivery_suspension, true) == true

  @doc "Children for the application's supervisor; none when off. Start after `SukhiFedi.AccountRepo`."
  @spec children() :: [module()]
  def children do
    if enabled?(), do: [SukhiShared.DeliverySuspension.Cache, __MODULE__.Upkeep], else: []
  end
end
