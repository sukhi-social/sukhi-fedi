# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Graph.Supervisor do
  @moduledoc "The graph store's `dtlv` child, opened on `schema.edn`."

  use Supervisor

  alias SukhiFedi.Datalevin.{Client, Config, SchemaFile}

  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    config = Keyword.get_lazy(opts, :config, &Config.current/0)
    config = %{config | dir: Keyword.get(opts, :dir, Path.join(config.dir, "graph"))}

    Supervisor.init(
      [
        {Client,
         name: SukhiFedi.Graph.client(),
         config: config,
         schema: SchemaFile.to_dtlv(SchemaFile.read())}
      ],
      strategy: :one_for_one,
      max_restarts: 5,
      max_seconds: 30
    )
  end
end
