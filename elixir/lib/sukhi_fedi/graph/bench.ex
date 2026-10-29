# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Graph.Bench do
  @moduledoc """
  A repeatable workload for the graph store, run by `mix sukhi.graph.bench`
  (and by `.github/workflows/graph-bench.yml`).

  It builds a small synthetic instance through the same door real traffic
  uses (`Graph.Activity.record/2`, so notifications are made too): a few
  hundred authors with a skewed popularity, threads, boosts, likes, one local
  actor who follows a hundred of them. Then it times each kind of read.
  The numbers say how the store behaves on *this* machine; the comparison
  between two runs on the same machine (`compare/2`) is the measurement.

  Data is deterministic for a given `:seed`, so two runs do the same work.
  """

  alias SukhiFedi.Graph
  alias SukhiFedi.Graph.{Activity, Actor, Read, Sweep, Tokens}

  @pub "https://www.w3.org/ns/activitystreams#Public"
  @me "https://local.example/users/me"
  @words ~w(cat dog fish bird rain sun moon tree river stone cloud wind fire snow tea rice bread song book game)

  @type opts :: %{
          objects: pos_integer(),
          authors: pos_integer(),
          follows: pos_integer(),
          samples: pos_integer(),
          seed: integer()
        }

  @spec defaults() :: opts()
  def defaults, do: %{objects: 5_000, authors: 200, follows: 100, samples: 100, seed: 42}

  @doc "Run the workload against a started graph. Returns the result map (JSON-able)."
  @spec run(opts(), keyword()) :: map()
  def run(opts, meta \\ []) do
    :rand.seed(:exsss, {opts.seed, opts.seed, opts.seed})

    raw_config = %SukhiFedi.RawStore.Config{
      backend: SukhiFedi.RawStore.SQLite,
      inline_max: 1_000_000
    }

    rec_opts = [raw_config: raw_config, followers: nil]

    authors = for i <- 1..opts.authors, do: "https://r.example/users/u#{i}"
    {:ok, _} = Actor.upsert_local(%{iri: @me, username: "me", sid: 1})

    for a <- authors,
        do:
          {:ok, _} =
            Actor.ingest(
              %{"id" => a, "type" => "Person", "preferredUsername" => Path.basename(a)},
              raw: "{}",
              raw_config: raw_config
            )

    follow_list = Enum.take(authors, opts.follows)

    for {f, i} <- Enum.with_index(follow_list) do
      id = "https://local.example/follows/#{i}"
      rec(%{"id" => id, "type" => "Follow", "actor" => @me, "object" => f}, rec_opts)

      rec(
        %{"type" => "Accept", "actor" => f, "object" => %{"id" => id, "actor" => @me}},
        rec_opts
      )
    end

    {ingest_us, ids} = ingest(opts, authors, follow_list, rec_opts)
    {tokens_ms, tokens_n} = tokens()

    reads = reads(opts, authors, ids, rec_opts)

    {sweep_us, sweep} =
      :timer.tc(fn -> Sweep.run(:dry_run, now: Graph.now() + 365 * 86_400 * 1_000_000) end)

    %{
      "label" => meta[:label] || "run",
      "params" =>
        Map.new(opts, fn {k, v} -> {Atom.to_string(k), v} end)
        |> Map.put("durability", meta[:durability]),
      "metrics" =>
        Map.merge(
          %{
            "ingest_per_activity_ms" => stats(ingest_us),
            "tokens_batch_ms" => %{"total" => tokens_ms, "objects" => tokens_n},
            "sweep_dry_run_ms" => %{"total" => sweep_us / 1000, "candidates" => sweep.candidates}
          },
          reads
        ),
      "size" => size(meta[:dir])
    }
  end

  # ---------------------------------------------------------------- workload

  defp ingest(opts, authors, follow_list, rec_opts) do
    # recent, so the home window is exercised as it is in life
    t0 = System.os_time(:second) - opts.objects * 20
    n_authors = length(authors)
    authors_t = List.to_tuple(authors)
    follow_t = List.to_tuple(follow_list)

    {times, ids} =
      Enum.reduce(1..opts.objects, {[], []}, fn i, {times, ids} ->
        # popularity is skewed: low-numbered authors write (and are read) more
        author = elem(authors_t, trunc(:math.pow(:rand.uniform(), 2) * n_authors))
        published = DateTime.from_unix!(t0 + i * 20) |> DateTime.to_iso8601()
        id = "https://r.example/notes/#{i}"

        reply =
          if ids != [] and :rand.uniform() < 0.3,
            do: Enum.at(ids, :rand.uniform(min(length(ids), 200)) - 1)

        {to, cc} = audience(:rand.uniform())

        note =
          %{
            "id" => id,
            "type" => "Note",
            "attributedTo" => author,
            "content" => "<p>" <> text() <> "</p>",
            "published" => published,
            "to" => to,
            "cc" => cc
          }
          |> then(&if(reply, do: Map.put(&1, "inReplyTo", reply), else: &1))
          |> then(
            &if(:rand.uniform() < 0.05,
              do: Map.put(&1, "tag", [%{"type" => "Mention", "href" => @me}]),
              else: &1
            )
          )

        create = %{
          "id" => id <> "/create",
          "type" => "Create",
          "actor" => author,
          "published" => published,
          "to" => to,
          "cc" => cc,
          "object" => note
        }

        us = timed(fn -> rec(create, rec_opts) end)

        extra =
          cond do
            :rand.uniform() < 0.20 ->
              [
                fn ->
                  rec(
                    %{
                      "id" => id <> "/like",
                      "type" => "Like",
                      "actor" => elem(follow_t, :rand.uniform(tuple_size(follow_t)) - 1),
                      "object" => id,
                      "published" => published
                    },
                    rec_opts
                  )
                end
              ]

            :rand.uniform() < 0.10 ->
              [
                fn ->
                  rec(
                    %{
                      "id" => id <> "/boost",
                      "type" => "Announce",
                      "actor" => elem(follow_t, :rand.uniform(tuple_size(follow_t)) - 1),
                      "object" => id,
                      "published" => published
                    },
                    rec_opts
                  )
                end
              ]

            true ->
              []
          end

        {[us | Enum.map(extra, &timed/1)] ++ times, [id | ids]}
      end)

    {times, Enum.reverse(ids)}
  end

  defp audience(r) when r < 0.88, do: {[@pub], []}
  defp audience(r) when r < 0.93, do: {[], [@pub]}
  defp audience(r) when r < 0.97, do: {["https://r.example/followers"], []}
  defp audience(_), do: {[@me], []}

  defp text, do: 1..30 |> Enum.map_join(" ", fn _ -> Enum.random(@words) end)

  defp rec(a, rec_opts) do
    raw = a |> :json.encode() |> IO.iodata_to_binary()
    :ok = Activity.record(a, Keyword.put(rec_opts, :raw, raw)) |> ok!()
  end

  defp ok!({:ignored, _}), do: :ok
  defp ok!(other), do: other

  defp tokens do
    {us, n} =
      :timer.tc(fn ->
        Stream.repeatedly(fn -> Tokens.run(limit: 1000, tokenizer: [engines: %{}]) end)
        |> Enum.reduce_while(0, fn %{done: d}, acc ->
          if d == 0, do: {:halt, acc}, else: {:cont, acc + d}
        end)
      end)

    {us / 1000, n}
  end

  # ------------------------------------------------------------------- reads

  defp reads(opts, authors, ids, rec_opts) do
    authors_t = List.to_tuple(authors)
    ids_t = List.to_tuple(ids)
    pick = fn t -> elem(t, :rand.uniform(tuple_size(t)) - 1) end

    page = Read.public(limit: 20)
    mid = Enum.at(page, 10)

    scenarios = [
      {"public_first_page", fn -> Read.public(limit: 20) end},
      {"public_deep_page", fn -> Read.public(limit: 20, before: mid.sid) end},
      {"local_first_page", fn -> Read.public(limit: 20, local: true) end},
      {"author_page", fn -> Read.author(pick.(authors_t), limit: 20) end},
      {"thread", fn -> Read.thread(pick.(ids_t)) end},
      {"home_first_page", fn -> Read.home(@me, limit: 20) end},
      {"notifications", fn -> Read.notifications(@me, limit: 20) end},
      {"search", fn -> Read.search(Enum.random(@words), limit: 20) end}
    ]

    # Datalevin caches query results until the next write, so repeating a
    # read on a quiet database times the cache. An instance is never quiet:
    # one write (untimed) goes in before every sample, so each read is cold.
    quiet_write = fn n ->
      author = pick.(authors_t)
      id = "https://r.example/notes/noise-#{n}-#{System.unique_integer([:positive])}"

      note = %{
        "id" => id,
        "type" => "Note",
        "attributedTo" => author,
        "content" => "<p>noise</p>",
        "published" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "to" => [@pub],
        "cc" => []
      }

      rec(
        %{"id" => id <> "/create", "type" => "Create", "actor" => author, "object" => note},
        rec_opts
      )
    end

    Map.new(scenarios, fn {name, fun} ->
      fun.()

      times =
        for n <- 1..opts.samples do
          quiet_write.(n)
          timed(fun)
        end

      {name <> "_ms", stats(times)}
    end)
  end

  defp timed(fun) do
    {us, _} = :timer.tc(fun)
    us
  end

  # --------------------------------------------------------------- reporting

  @doc "Summary of microsecond timings in milliseconds."
  @spec stats([number()]) :: map()
  def stats(us) do
    sorted = Enum.sort(us)
    n = length(sorted)
    at = fn q -> Enum.at(sorted, min(n - 1, trunc(q * n))) / 1000 end

    %{
      "n" => n,
      "p50" => round3(at.(0.5)),
      "p95" => round3(at.(0.95)),
      "max" => round3(List.last(sorted) / 1000),
      "total" => round3(Enum.sum(sorted) / 1000)
    }
  end

  defp round3(x), do: Float.round(x * 1.0, 3)

  defp size(nil), do: %{}

  defp size(dir) do
    # blocks actually used (`du`), not the sparse LMDB map's apparent size
    {out, 0} = System.cmd("du", ["-sk", dir])
    kb = out |> String.split() |> hd() |> String.to_integer()
    rss = rss_kb(Graph.client())

    %{
      "graph_dir_mb" => round3(kb / 1024),
      "dtlv_rss_mb" => round3(rss / 1024),
      "beam_total_mb" => round3(:erlang.memory(:total) / 1_048_576)
    }
  end

  defp rss_kb(client) do
    pid = SukhiFedi.Datalevin.Client.os_pid(client)

    case File.read("/proc/#{pid}/status") do
      {:ok, text} ->
        (Regex.run(~r/VmRSS:\s+(\d+)/, text) || [nil, "0"]) |> Enum.at(1) |> String.to_integer()

      _ ->
        0
    end
  end

  @doc """
  Markdown table of `head`, and — when `base` is given — the change against
  it. A row is flagged only when p95 is more than 25% worse **and** more than
  2 ms worse: a shared runner is noisy and the table reports, it does not gate.
  """
  @spec markdown(map(), map() | nil) :: String.t()
  def markdown(head, base) do
    rows =
      head["metrics"]
      |> Enum.filter(fn {_, m} -> Map.has_key?(m, "p95") end)
      |> Enum.sort()
      |> Enum.map(fn {name, m} ->
        b = base && get_in(base, ["metrics", name])
        base_cols = if b, do: " #{cell(b["p95"])} | #{delta(m["p95"], b["p95"])} |", else: ""
        "| #{name} | #{cell(m["p50"])} | #{cell(m["p95"])} |#{base_cols}"
      end)

    header =
      if base,
        do: "| metric | p50 ms | p95 ms | base p95 | change |\n|---|---:|---:|---:|---:|",
        else: "| metric | p50 ms | p95 ms |\n|---|---:|---:|"

    other =
      head["metrics"]
      |> Enum.reject(fn {_, m} -> Map.has_key?(m, "p95") end)
      |> Enum.sort()
      |> Enum.map(fn {name, m} ->
        "- **#{name}**: " <> Enum.map_join(m, ", ", fn {k, v} -> "#{k} #{v}" end)
      end)

    sizes = Enum.map(head["size"] || %{}, fn {k, v} -> "- **#{k}**: #{v}" end)

    Enum.join(
      [
        "### graph bench: #{head["label"]}",
        "",
        Enum.join(rows, "\n") |> then(&(header <> "\n" <> &1)),
        "",
        Enum.join(other ++ sizes, "\n")
      ],
      "\n"
    )
  end

  defp cell(x) when is_number(x), do: :erlang.float_to_binary(x * 1.0, decimals: 2)
  defp cell(_), do: "-"

  defp delta(h, b) when is_number(h) and is_number(b) and b > 0 do
    pct = (h - b) / b * 100
    flag = if pct > 25 and h - b > 2, do: " ⚠", else: ""
    "#{if pct >= 0, do: "+"}#{Float.round(pct, 0) |> trunc()}%#{flag}"
  end

  defp delta(_, _), do: "-"
end
