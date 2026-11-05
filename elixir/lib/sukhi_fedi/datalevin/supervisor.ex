# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Datalevin.Supervisor do
  @moduledoc """
  The processes of the Datalevin store: the `dtlv` child, the writer lock and
  the id counters. If the child dies it is restarted and reopens the same
  directory; callers that were waiting get an error. It refuses to start on a
  store with migrations pending (`Migrator.check_current!/2`).
  """

  use Supervisor

  alias SukhiFedi.Datalevin.{Catalog, Client, Config, Ids, Lock, Migrator}

  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    config = Keyword.get_lazy(opts, :config, &Config.current/0)

    # A store that has migrations left (or data a newer release wrote) must
    # not be opened: `Release.migrate_all/0` goes first.
    :ok = Migrator.check_current!(Migrator.spec(:main, config, Catalog.dtlv_schema(), ""))

    children = [
      %{id: Ids, start: {Ids, :start_link, [[]]}, restart: :temporary},
      Lock,
      {Client, config: config, schema: Catalog.dtlv_schema()}
    ]

    Supervisor.init(children, strategy: :rest_for_one, max_restarts: 5, max_seconds: 30)
  end
end
