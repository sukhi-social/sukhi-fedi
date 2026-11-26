# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiDelivery.Store.Adapter do
  @moduledoc """
  The adapter `SukhiDelivery.Repo` is built with: hosigraph, through `Ecto.Adapters.Hosi`.

  The store is owned by the gateway (`SukhiFedi.Repo` starts it); this repo
  only joins it, so the two apps in a combined release read and write one
  database. A delivery node on its own has no store to join: it needs the
  combined release. See `SukhiShared.StoreAdapter`.
  """

  use SukhiShared.StoreAdapter,
    adapter: Ecto.Adapters.Hosi,
    owner?: false
end
