# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Store.Adapter do
  @moduledoc """
  The `Ecto.Adapter` that `SukhiFedi.Repo` is built with. It owns no behaviour
  of its own: `SukhiShared.StoreAdapter` hands every callback to
  `Ecto.Adapters.Hosi` (ecto_hosi), the only store there is (docs/STORE.md).

  This repo owns the hosigraph processes; the delivery node's repo joins them.
  """

  use SukhiShared.StoreAdapter,
    adapter: Ecto.Adapters.Hosi,
    owner?: true
end
