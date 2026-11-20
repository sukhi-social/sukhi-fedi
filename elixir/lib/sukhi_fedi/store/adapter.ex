# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Store.Adapter do
  @moduledoc """
  The `Ecto.Adapter` that `SukhiFedi.Repo` is built with. It owns no behaviour
  of its own: `SukhiShared.StoreAdapter` hands every callback to
  `SukhiFedi.Datalevin.Adapter`, the only store there is (docs/DATALEVIN.md).

  This repo owns the Datalevin processes; the delivery node's repo joins them.
  """

  use SukhiShared.StoreAdapter,
    datalevin: SukhiFedi.Datalevin.Adapter,
    owner?: true
end
