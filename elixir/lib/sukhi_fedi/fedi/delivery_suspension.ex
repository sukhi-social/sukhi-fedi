# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Fedi.DeliverySuspension do
  @moduledoc """
  FEP-f799 on the gateway side (docs/DELIVERY_SUSPENSION.md): what to start,
  and the parts that are started.

    * `Receiver` — takes in a notice and its cancellation;
    * `Store` — remembers them (the graph store);
    * `Upkeep` — fills the delivery worker's ETS copy
      (`SukhiShared.DeliverySuspension.Cache`) from the store when the gateway
      starts, and forgets the old once an hour.

  It needs the graph store; without `SUKHI_GRAPH=1` nothing here starts, the
  cache has no table, and no delivery is ever held.
  """

  alias SukhiFedi.Graph

  @doc "Children for the application's supervisor; none when the graph is off. Start after `Graph.children/0`."
  @spec children() :: [module()]
  def children do
    if Graph.enabled?(), do: [SukhiShared.DeliverySuspension.Cache, __MODULE__.Upkeep], else: []
  end
end
