# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Datalevin.Migration.Ctx do
  @moduledoc """
  What a running migration is handed: the store's `dtlv` child (opened by the
  migrator for this run alone), its configuration, and which store it is.
  """

  alias SukhiFedi.Datalevin.Config

  @enforce_keys [:client, :config, :store]
  defstruct [:client, :config, :store]

  @type t :: %__MODULE__{
          client: GenServer.server(),
          config: Config.t(),
          store: SukhiFedi.Datalevin.Migration.store()
        }
end
