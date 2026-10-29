# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Graph.Tokens do
  @moduledoc """
  The batch that makes text searchable.

  Datalevin's full-text index splits on spaces, so text is segmented first
  (`SukhiFedi.Tokenizer`) and the space-separated result is written to
  `object/tokens` / `content/tokens`. Ingest never does this: writing a post
  must not wait for, or fail with, a segmentation service. `run/1` finds what
  has no tokens yet and fills it in, `limit` entities at a time. Running it
  again is how a down service, or a new dictionary, is recovered from
  (`reset/0` drops the tokens so the next run rebuilds them from the text).

  Real-time segmentation at ingest is deliberately not provided; it would be
  a thin call to `segment_object/2` from the ingest path, if it is ever wanted.

  The search side must segment the query with the same tokenizer:
  `query_text/2`.
  """

  alias SukhiFedi.{Graph, Tokenizer}

  @type report :: %{done: non_neg_integer(), degraded: non_neg_integer(), stopped: boolean()}

  @doc """
  Segment up to `:limit` (default 200) entities without tokens. Stops at the
  first `:degraded` answer (the service is down: do not spin on every entity).
  `:tokenizer` is the options for `SukhiFedi.Tokenizer.segment/3`.
  """
  @spec run(keyword()) :: report()
  def run(opts \\ []) do
    limit = Keyword.get(opts, :limit, 200)
    tok = Keyword.get(opts, :tokenizer, [])

    pending = Enum.take(objects(limit) ++ bodies(limit), limit)

    Enum.reduce_while(pending, %{done: 0, degraded: 0, stopped: false}, fn
      {eid, attr, text, lang}, acc ->
        case Tokenizer.segment(plain(text), lang, tok) do
          {:ok, tokens} ->
            {:ok, _} = Graph.transact([%{":db/id" => eid, attr => tokens}])
            {:cont, %{acc | done: acc.done + 1}}

          {:degraded, _} ->
            {:halt, %{acc | degraded: acc.degraded + 1, stopped: true}}
        end
    end)
  end

  @doc "Forget every token, so the next `run/1` rebuilds them (new dictionary, new tokenizer)."
  @spec reset() :: {:ok, non_neg_integer()}
  def reset do
    tx =
      for attr <- [":object/tokens", ":content/tokens"],
          [e] <- Graph.query!("[:find ?e :where [?e #{attr} _]]"),
          do: [":db.fn/retractAttribute", e, attr]

    if tx != [], do: {:ok, _} = Graph.transact(tx)
    {:ok, length(tx)}
  end

  @doc "How much is still unsegmented: `{objects, bodies}`."
  @spec pending() :: {non_neg_integer(), non_neg_integer()}
  def pending do
    count = fn edn ->
      case Graph.query!(edn) do
        [[n]] -> n
        [] -> 0
      end
    end

    {count.("[:find (count ?o) :where [?o :object/content-html _] (not [?o :object/tokens _])]"),
     count.("[:find (count ?c) :where [?c :content/text _] (not [?c :content/tokens _])]")}
  end

  @doc "The text of a search, segmented as the indexed text was (`language` of the searcher's content, if known)."
  @spec query_text(String.t(), String.t() | nil, keyword()) :: String.t()
  def query_text(text, language, tok \\ []) do
    case Tokenizer.segment(text, language, tok) do
      {_, segmented} -> segmented
    end
  end

  defp objects(limit) do
    langs =
      Map.new(Graph.query!("[:find ?o ?l :where [?o :object/language ?l]]"), fn [o, l] ->
        {o, l}
      end)

    for [o, html] <-
          Graph.query!(
            "[:find ?o ?h :where [?o :object/content-html ?h] (not [?o :object/tokens _]) :limit #{limit}]"
          ) do
      {o, ":object/tokens", html, Map.get(langs, o)}
    end
  end

  defp bodies(limit) do
    for [c, text, lang] <-
          Graph.query!(
            "[:find ?c ?t ?l :where [?c :content/text ?t] [?c :content/lang ?l] (not [?c :content/tokens _]) :limit #{limit}]"
          ) do
      {c, ":content/tokens", text, lang}
    end
  end

  # HTML → the text a reader would search: tags dropped, entities decoded.
  @doc false
  @spec plain(String.t()) :: String.t()
  def plain(html) do
    html
    |> String.replace(~r/<br\s*\/?>|<\/p>/i, " ")
    |> String.replace(~r/<[^>]*>/u, "")
    |> SukhiFedi.HTML.unescape()
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
  end
end
