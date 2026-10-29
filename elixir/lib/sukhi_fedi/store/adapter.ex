# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Store.Adapter do
  @moduledoc """
  The `Ecto.Adapter` that `SukhiFedi.Repo` is built with. It owns no behaviour
  of its own: `SukhiShared.StoreAdapter` asks `SukhiFedi.Store.kind/0` for
  every callback and hands the call to `Ecto.Adapters.Postgres` or to
  `SukhiFedi.Datalevin.Adapter`.

  That is what lets `SUKHI_STORE` be a runtime switch rather than a compile-time
  one: the release is built once. This repo owns the Datalevin processes; the
  delivery node's repo joins them (docs/DATALEVIN.md).
  """

  use SukhiShared.StoreAdapter,
    app: :sukhi_fedi,
    datalevin: SukhiFedi.Datalevin.Adapter,
    owner?: true
end
