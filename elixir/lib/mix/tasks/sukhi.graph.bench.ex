# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule Mix.Tasks.Sukhi.Graph.Bench do
  @shortdoc "Benchmark the graph store on a real dtlv"
  @moduledoc """
  Builds a synthetic instance in a throwaway directory, times ingest and each
  read (`SukhiFedi.Graph.Bench`), prints a Markdown table and writes JSON.

      mix sukhi.graph.bench --objects 5000 --durability relaxed --out out/head.json
      mix sukhi.graph.bench --baseline out/base.json --out out/head.json

  Options: `--objects` `--authors` `--follows` `--samples` `--seed`,
  `--durability` (strict | relaxed | lmdb | nosync; default relaxed),
  `--dtlv` (the binary; default `DATALEVIN_BIN` or `dtlv`), `--label`,
  `--out` (JSON), `--baseline` (a previous JSON to compare with).
  """

  use Mix.Task

  alias SukhiFedi.Graph.Bench

  @switches [
    objects: :integer,
    authors: :integer,
    follows: :integer,
    samples: :integer,
    seed: :integer,
    durability: :string,
    dtlv: :string,
    label: :string,
    out: :string,
    baseline: :string
  ]

  @impl Mix.Task
  def run(args) do
    {parsed, _} = OptionParser.parse!(args, strict: @switches)
    Mix.Task.run("app.config")
    {:ok, _} = Application.ensure_all_started(:logger)

    dir = Path.join(System.tmp_dir!(), "graph_bench_#{System.unique_integer([:positive])}")
    durability = parsed[:durability] || "relaxed"

    config =
      SukhiFedi.Datalevin.Config.from_env(%{
        "DATALEVIN_DIR" => dir,
        "DATALEVIN_BIN" => parsed[:dtlv] || System.get_env("DATALEVIN_BIN", "dtlv"),
        "DATALEVIN_DURABILITY" => durability
      })

    graph_dir = Path.join(dir, "graph")
    {:ok, _} = SukhiFedi.Graph.Supervisor.start_link(config: config, dir: graph_dir)

    opts =
      Map.merge(
        Bench.defaults(),
        Map.take(Map.new(parsed), [:objects, :authors, :follows, :samples, :seed])
      )

    result =
      Bench.run(opts, label: parsed[:label] || "head", durability: durability, dir: graph_dir)

    base =
      parsed[:baseline] && File.exists?(parsed[:baseline]) &&
        parsed[:baseline] |> File.read!() |> :json.decode()

    Mix.shell().info(Bench.markdown(result, base || nil))

    if out = parsed[:out] do
      File.mkdir_p!(Path.dirname(out))
      File.write!(out, :json.encode(result) |> IO.iodata_to_binary())
    end

    File.rm_rf!(dir)
  end
end
