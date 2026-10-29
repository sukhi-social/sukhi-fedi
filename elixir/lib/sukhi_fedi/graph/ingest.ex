# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Graph.Ingest do
  @moduledoc """
  Write one ActivityPub object into the graph.

  The caller has already verified and classified the delivery; this turns the
  JSON into one transaction. It is an upsert by IRI, so the same object
  arriving twice (a boost, a re-fetch, an `Update`) is one entity.

    * The author, every addressee and the mentioned actors are written as
      stubs (`actor/id` only) if unknown; a later fetch fills them in. Remote
      actors are never removed by cleanup, so a stub is safe to leave.
    * `to`/`cc` point at `actor` or `collection` entities (`as:Public`, the
      author's followers); `object/visibility` is derived once, by
      `SukhiFedi.Graph.Audience.visibility/3`.
    * `object/root` is the thread's first known object (a root points at
      itself), so a whole thread is one range and a cleanup can keep it whole.
    * The original goes through `SukhiFedi.RawStore`; the caller passes the
      exact bytes it received as `:raw`.
    * `object/tokens` is *not* written here: segmenting is a batch
      (`SukhiFedi.Graph.Tokens`). An object without `tokens` is simply not
      yet searchable.
    * `sid` is a Snowflake minted from the published time, kept stable across
      re-ingests.

  Options: `:raw` (required binary), `:local?` (default false), `:followers`
  (the author's followers collection IRI), `:now` (µs), `:raw_config`.
  """

  alias SukhiFedi.{Graph, RawStore, Snowflake}
  alias SukhiFedi.Graph.Audience

  @type result ::
          {:ok, %{id: String.t(), sid: integer(), visibility: Audience.visibility()}}
          | {:error, term()}

  @object -1
  @author -2
  @parent -3
  @root -4

  @misskey_source ["text/x.misskeymarkdown", "text/x.misskey-mfm"]

  @spec object(map(), keyword()) :: result()
  def object(%{"id" => id} = json, opts) when is_binary(id) do
    raw = Keyword.fetch!(opts, :raw)

    with {:ok, author} <- author(json),
         {:ok, raw_attrs} <-
           RawStore.put(
             "object",
             raw,
             Keyword.get_lazy(opts, :raw_config, &RawStore.Config.current/0)
           ) do
      Graph.exclusive(fn -> write(id, author, json, raw_attrs, opts) end)
    end
  end

  def object(_json, _opts), do: {:error, :invalid_object}

  @doc """
  A remote `Delete`: keep the identity, drop the content. The object becomes a
  Tombstone (`deleted-at`), and its text, original and per-language bodies go.
  """
  @spec tombstone(String.t(), integer()) :: {:ok, :deleted | :unknown} | {:error, term()}
  def tombstone(id, at \\ Graph.now()) do
    Graph.exclusive(fn ->
      case Graph.query!("[:find ?o :where [?o :object/id #{lit(id)}]]") do
        [[eid]] ->
          bodies = Graph.query!("[:find ?c :where [?c :content/object #{eid}]]")

          retracts =
            for attr <- ~w(content-html content-mfm tokens summary raw raw-ref raw-size title),
                do: [":db.fn/retractAttribute", eid, ":object/#{attr}"]

          tx =
            [%{":db/id" => eid, ":object/type" => ":Tombstone", ":object/deleted-at" => at}] ++
              retracts ++ for [c] <- bodies, do: [":db.fn/retractEntity", c]

          with {:ok, _} <- Graph.transact(tx), do: {:ok, :deleted}

        [] ->
          {:ok, :unknown}
      end
    end)
  end

  # ------------------------------------------------------------------ write

  defp write(id, author, json, raw_attrs, opts) do
    now = Keyword.get_lazy(opts, :now, &Graph.now/0)
    published = Graph.micros(json["published"]) || now
    to = Audience.iris(json["to"])
    cc = Audience.iris(json["cc"])
    followers = opts[:followers]
    visibility = Audience.visibility(to, cc, followers)
    parent = json |> Map.get("inReplyTo") |> Audience.iris() |> List.first()
    {root_iri, root_stub} = root(id, parent)

    sid = sid(id, published)
    addressees = addressees(to ++ cc, followers)
    mentions = mentions(json)

    object =
      compact(%{
        ":db/id" => @object,
        ":object/id" => id,
        ":object/sid" => sid,
        ":object/type" => keyword(json["type"] || "Note"),
        ":object/attributed-to" => @author,
        ":object/local?" => Keyword.get(opts, :local?, false),
        ":object/published" => published,
        ":object/updated" => Graph.micros(json["updated"]),
        ":object/received-at" => now,
        ":object/touched-at" => now,
        ":object/visibility" => keyword(Atom.to_string(visibility)),
        ":object/to" => refs(addressees, to),
        ":object/cc" => refs(addressees, cc),
        ":object/mentions" => Enum.map(mentions, & &1.tmp),
        ":object/content-html" => string(json["content"]),
        ":object/content-mfm" => mfm(json),
        ":object/summary" => string(json["summary"]),
        ":object/title" => string(json["name"]),
        ":object/sensitive?" => if(is_boolean(json["sensitive"]), do: json["sensitive"]),
        ":object/language" => language(json),
        ":object/in-reply-to" => if(parent, do: @parent),
        ":object/root" => root_ref(id, parent, root_iri)
      })
      |> Map.merge(Map.new(raw_attrs, fn {k, v} -> {":" <> Atom.to_string(k), v} end))

    tx =
      [%{":db/id" => @author, ":actor/id" => author}] ++
        Enum.map(addressees, & &1.entity) ++
        Enum.map(mentions, & &1.entity) ++
        parent_entities(id, parent, root_iri, root_stub) ++
        rehome(id, root_ref(id, parent, root_iri)) ++
        [object] ++ bodies(json, @object) ++ hashtags(json, @object, published)

    with {:ok, _} <- Graph.transact(tx), do: {:ok, %{id: id, sid: sid, visibility: visibility}}
  end

  # Tempids: a root points at itself; a reply's root is the parent's root, or
  # the parent when that has none yet.
  defp root_ref(id, _parent, id), do: @object
  defp root_ref(_id, parent, parent), do: @parent
  defp root_ref(_id, _parent, _root), do: @root

  # Replies that arrived before this object took it for their thread's root.
  # Now that it knows its own root, they follow it.
  defp rehome(_id, root_tmp) when root_tmp == @object, do: []

  defp rehome(id, root_tmp) do
    for [child] <-
          Graph.query!(
            "[:find ?c :where [?x :object/id #{lit(id)}] [?c :object/root ?x] [(not= ?c ?x)]]"
          ) do
      [":db/add", child, ":object/root", root_tmp]
    end
  end

  # The parent (and its root, when different) are written as stubs. A parent
  # that has no root yet becomes its own thread's root.
  defp parent_entities(_id, nil, _root, _stub), do: []

  defp parent_entities(_id, parent, root_iri, stub) do
    root_ent =
      if root_iri == parent, do: [], else: [%{":db/id" => @root, ":object/id" => root_iri}]

    base = %{":db/id" => @parent, ":object/id" => parent}

    parent_ent =
      if stub == :new and root_iri == parent,
        do: Map.put(base, ":object/root", @parent),
        else: base

    root_ent ++ [parent_ent]
  end

  # {root IRI, whether the parent already carries a root}
  defp root(id, nil), do: {id, :new}

  defp root(_id, parent) do
    case Graph.query!(
           "[:find ?r :where [?p :object/id #{lit(parent)}] [?p :object/root ?rr] [?rr :object/id ?r]]"
         ) do
      [[root]] -> {root, :known_root}
      [] -> {parent, :new}
    end
  end

  # Existing sid wins (stable across re-ingests); otherwise the first free
  # Snowflake counter for this millisecond. Called under `Graph.exclusive/1`.
  defp sid(id, published) do
    case Graph.query!("[:find ?s :where [?o :object/id #{lit(id)}] [?o :object/sid ?s]]") do
      [[sid]] ->
        sid

      [] ->
        ms = div(published, 1000)
        {lo, hi} = {Snowflake.encode(ms, 0), Snowflake.encode(ms, 65_535)}

        taken =
          Graph.query!(
            "[:find (max ?s) :where [_ :object/sid ?s] [(>= ?s #{lo})] [(<= ?s #{hi})]]"
          )

        case taken do
          [[max]] when is_integer(max) and max < hi ->
            max + 1

          [[max]] when is_integer(max) ->
            raise "no free sid in #{ms}ms (65536 objects at one millisecond)"

          _ ->
            lo
        end
    end
  end

  # -------------------------------------------------------------- addressees

  defp addressees(iris, followers) do
    iris
    |> Enum.uniq()
    |> Enum.with_index()
    |> Enum.map(fn {iri, i} ->
      tmp = -(10 + i)

      entity =
        cond do
          Audience.public?(iri) ->
            %{
              ":db/id" => tmp,
              ":collection/id" => Audience.public(),
              ":collection/kind" => ":public"
            }

          iri == followers ->
            %{":db/id" => tmp, ":collection/id" => iri, ":collection/kind" => ":followers"}

          true ->
            %{":db/id" => tmp, ":actor/id" => iri}
        end

      %{iri: iri, tmp: tmp, entity: entity}
    end)
  end

  defp refs(addressees, iris) do
    wanted = MapSet.new(iris)
    for a <- addressees, MapSet.member?(wanted, a.iri), do: a.tmp
  end

  defp mentions(json) do
    json
    |> Map.get("tag", [])
    |> List.wrap()
    |> Enum.filter(&(is_map(&1) and &1["type"] == "Mention" and is_binary(&1["href"])))
    |> Enum.map(& &1["href"])
    |> Enum.uniq()
    |> Enum.with_index()
    |> Enum.map(fn {iri, i} ->
      tmp = -(1000 + i)
      %{iri: iri, tmp: tmp, entity: %{":db/id" => tmp, ":actor/id" => iri}}
    end)
  end

  # ------------------------------------------------------------------ bodies

  # contentMap with more than one language: one entity per (language, kind).
  defp bodies(%{"contentMap" => %{} = map}, object) when map_size(map) > 1 do
    for {lang, text} <- map, is_binary(text), lang != "" do
      %{
        ":content/object" => object,
        ":content/lang" => lang,
        ":content/kind" => ":content",
        ":content/text" => text
      }
    end
  end

  defp bodies(_json, _object), do: []

  defp hashtags(json, object, published) do
    json
    |> Map.get("tag", [])
    |> List.wrap()
    |> Enum.filter(&(is_map(&1) and &1["type"] == "Hashtag" and is_binary(&1["name"])))
    |> Enum.map(&(&1["name"] |> String.trim_leading("#") |> String.downcase()))
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> Enum.map(fn tag ->
      %{":tagging/tag" => tag, ":tagging/object" => object, ":tagging/published" => published}
    end)
  end

  # ----------------------------------------------------------------- helpers

  defp author(%{"attributedTo" => a}), do: author_iri(a)
  defp author(%{"actor" => a}), do: author_iri(a)
  defp author(_), do: {:error, :no_author}

  defp author_iri(a) do
    case Audience.iris(a) do
      [iri | _] -> {:ok, iri}
      [] -> {:error, :no_author}
    end
  end

  defp mfm(%{"source" => %{"content" => c, "mediaType" => t}})
       when is_binary(c) and t in @misskey_source, do: c

  defp mfm(%{"_misskey_content" => c}) when is_binary(c), do: c
  defp mfm(_), do: nil

  defp language(%{"contentMap" => %{} = m}) when map_size(m) > 0,
    do: m |> Map.keys() |> Enum.sort() |> hd()

  defp language(_), do: nil

  defp string(s) when is_binary(s) and s != "", do: s
  defp string(_), do: nil

  # A type name from the wire becomes a keyword *value* (text), never an atom.
  defp keyword(name) when is_binary(name), do: ":" <> name

  defp compact(map), do: map |> Enum.reject(fn {_, v} -> is_nil(v) or v == [] end) |> Map.new()

  defp lit(s), do: SukhiFedi.Datalevin.Edn.literal(s)
end
