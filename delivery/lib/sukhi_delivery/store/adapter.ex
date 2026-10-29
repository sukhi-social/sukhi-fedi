# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiDelivery.Store.Adapter do
  @moduledoc """
  The adapter `SukhiDelivery.Repo` is built with: Postgres by default, or the
  Datalevin store when the node runs with `SUKHI_STORE=datalevin`.

  The Datalevin store is owned by the gateway (`SukhiFedi.Repo` starts it);
  this repo only joins it, so the two apps in a combined release read and
  write one database. A delivery node on its own has no Datalevin to join:
  that store needs the combined release. See `SukhiShared.StoreAdapter`.
  """

  use SukhiShared.StoreAdapter,
    app: :sukhi_delivery,
    datalevin: SukhiFedi.Datalevin.Adapter,
    owner?: false
end
