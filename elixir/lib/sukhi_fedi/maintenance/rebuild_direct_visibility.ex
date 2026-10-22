# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Maintenance.RebuildDirectVisibility do
  @moduledoc """
  One-off: repair remote notes stored `direct` only because the fetch
  path saw the compact `as:Public` addressing, which the old
  `Extract.public?/1` didn't recognise (fixed alongside this module).

  Inbox-delivered activities arrive expanded, so they were always
  classified right; only a *fetched* object (a reply/quote parent pulled
  in by id) kept the compact `as:Public` and got demoted to `direct` —
  hiding public posts inside DMs and off every timeline.

  Re-fetch each remote `direct` note and re-derive its visibility with
  the fixed predicate. Fetch-first and one-directional: a note we cannot
  fetch (a genuine DM whose origin 404s or refuses unauthenticated
  reads) is left `direct`, untouched. We only ever *widen* visibility,
  and only on positive proof the origin addressed it publicly — never
  the reverse, so this can't leak a real DM.

  Run on the gateway (it owns the Repo and the federation fetch path):

      bin/sukhi_fedi eval 'SukhiFedi.Maintenance.RebuildDirectVisibility.run(:dry_run)'
      bin/sukhi_fedi eval 'SukhiFedi.Maintenance.RebuildDirectVisibility.run(:execute)'
  """

  import Ecto.Query
  require Logger

  alias SukhiFedi.AP.Instructions.Extract
  alias SukhiFedi.Federation.FedifyClient
  alias SukhiFedi.Maintenance.Progress
  alias SukhiFedi.Repo
  alias SukhiFedi.Schema.Note

  @spec run(:dry_run | :execute) :: map()
  def run(mode \\ :dry_run) do
    targets = target_notes()
    Logger.info("rebuild_direct_visibility: mode=#{mode}, candidates=#{length(targets)}")

    # The origin fetch happens in both modes, so both are worth showing.
    run = Progress.start("rebuild_direct_visibility", mode, length(targets), "checking")
    {results, run} = Progress.map(run, targets, fn n -> {n, classify(n)} end, fn _ -> :ok end)

    for {n, {:rewrite, v}} <- results do
      Logger.info("  ##{n.id} #{n.ap_id}: direct -> #{v}")
    end

    if mode == :execute do
      for {n, {:rewrite, v}} <- results do
        n |> Ecto.Changeset.change(visibility: v) |> Repo.update!()
      end
    end

    summary = %{
      mode: mode,
      candidates: length(targets),
      rewrites: for({n, {:rewrite, v}} <- results, do: {n.id, v}),
      kept_direct: for({n, :keep} <- results, do: n.id)
    }

    Progress.finish(run, %{
      candidates: summary.candidates,
      rewrites: length(summary.rewrites),
      kept_direct: length(summary.kept_direct)
    })

    summary
  end

  @doc "Remote notes currently stored as `direct`."
  def target_notes do
    from(n in Note, where: not is_nil(n.domain) and n.visibility == "direct", order_by: n.id)
    |> Repo.all()
  end

  # Positive proof or nothing: only a successful fetch whose re-derived
  # addressing is wider than `direct` rewrites the row.
  defp classify(%Note{} = n) do
    case fetch(n.ap_id) do
      {:ok, json} ->
        case Extract.visibility_from(json) do
          "direct" -> :keep
          v -> {:rewrite, v}
        end

      {:error, reason} ->
        Logger.warning("  skip ##{n.id} (#{n.ap_id}): fetch failed #{inspect(reason)}")
        :keep
    end
  end

  defp fetch(uri) do
    case FedifyClient.fetch(uri, SukhiFedi.Accounts.signing_identity()) do
      {:ok, %{"document" => doc}} when is_map(doc) -> {:ok, doc}
      {:ok, other} -> {:error, {:unexpected_fetch_result, other}}
      {:error, _} = err -> err
    end
  end
end
