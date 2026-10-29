# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Graph.Timelines do
  @moduledoc """
  The graph chooses which posts a timeline shows, and in what order; the
  relational store still supplies the post itself (counts, media, who the
  reader is). `SukhiFedi.Timelines` asks `page/3` first and loads the notes
  for the IRIs it returns, so the Mastodon JSON is built by the same code
  whichever store picked the page.

  `page/3` answers `:fallback` — and the caller runs its usual query — when
  the graph cannot answer *exactly*: a filter only the relational query
  knows (`only_media`, `hide_sensitive`), a forward cursor (`since_id`,
  `min_id`), a short page, a cursor post the graph does not hold, or any failure. A
  timeline is never emptier because the graph is on.

  A Mastodon `max_id` is a note id; the graph pages by its own `sid`, so the
  cursor goes id → `ap_id` → `sid`.
  """

  import Ecto.Query

  require Logger

  alias SukhiFedi.{Graph, Repo}
  alias SukhiFedi.Datalevin.Edn
  alias SukhiFedi.Schema.Note

  @doc """
  `fun` receives the read options (`:limit`, `:before`, `:local`) and returns
  `Graph.Read` rows. `{:ok, iris}` is the page, newest first.
  """
  @spec page(map(), (keyword() -> [map()])) :: {:ok, [String.t()]} | :fallback
  def page(opts, fun) do
    with true <- exact?(opts),
         {:ok, before} <- before(opts[:max_id]) do
      limit = limit(opts)

      read =
        [limit: limit, local: Map.get(opts, :local, true)] ++
          if(before, do: [before: before], else: [])

      case fun.(read) do
        rows when length(rows) >= limit -> {:ok, Enum.map(rows, & &1.id)}
        _short -> :fallback
      end
    else
      _ -> :fallback
    end
  rescue
    e ->
      Logger.warning("graph timeline: #{Exception.message(e)}")
      :fallback
  end

  @doc "The notes for `iris`, in that order. IRIs the relational store lacks drop out."
  @spec notes([String.t()], keyword()) :: [Note.t()]
  def notes(iris, opts \\ []) do
    silenced = Keyword.get(opts, :silenced, [])
    order = iris |> Enum.with_index() |> Map.new()

    from(n in Note, where: n.ap_id in ^iris and n.account_id not in ^silenced)
    |> Repo.all()
    |> Enum.sort_by(&Map.fetch!(order, &1.ap_id))
  end

  @doc "`page/2` for a list timeline (`list_sid` = the list's id); there is no local/remote split."
  @spec list_page(integer(), map()) :: {:ok, [String.t()]} | :fallback
  def list_page(list_sid, opts), do: page(opts, &SukhiFedi.Graph.Read.list(list_sid, &1))

  defp exact?(opts) do
    Enum.all?([:since_id, :min_id, :only_media, :hide_sensitive], &(opts[&1] in [nil, false]))
  end

  defp limit(opts), do: min(max(Map.get(opts, :limit, 20), 1), 40)

  defp before(nil), do: {:ok, nil}

  defp before(max_id) when is_integer(max_id) do
    with ap when is_binary(ap) <-
           Repo.one(from(n in Note, where: n.id == ^max_id, select: n.ap_id)),
         [[sid]] <-
           Graph.query!(
             "[:find ?s :where [?o :object/id #{Edn.literal(ap)}] [?o :object/sid ?s]]"
           ) do
      {:ok, sid}
    else
      _ -> :error
    end
  end
end
