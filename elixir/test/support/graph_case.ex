# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.GraphCase do
  @moduledoc """
  A throwaway graph database on a real `dtlv` for one test. Tagged `:dtlv`;
  `test_helper.exs` leaves those out when no `dtlv` binary is found.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      @moduletag :dtlv
      alias SukhiFedi.Graph
    end
  end

  setup do
    dir = Path.join(System.tmp_dir!(), "graph_test_#{System.unique_integer([:positive])}")

    config =
      SukhiFedi.Datalevin.Config.from_env(%{
        "DATALEVIN_DIR" => dir,
        "DATALEVIN_BIN" => System.get_env("DATALEVIN_BIN", "dtlv"),
        "DATALEVIN_DURABILITY" => "nosync"
      })

    start_supervised!({SukhiFedi.Graph.Supervisor, config: config, dir: dir})
    {:ok, agent} = Agent.start_link(fn -> %{} end)
    on_exit(fn -> File.rm_rf(dir) end)

    raw_config = %SukhiFedi.RawStore.Config{
      backend: SukhiFedi.TestMemBlobs,
      backend_opts: [agent: agent, now: 0],
      inline_max: 64,
      grace_s: 10
    }

    %{raw_config: raw_config, blobs: agent}
  end
end
