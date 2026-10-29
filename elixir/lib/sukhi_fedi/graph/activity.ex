# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Graph.Activity do
  @moduledoc """
  The edges: what an actor did to an object or to another actor.

  `record/2` takes one verified activity and writes the activity, the edge
  it makes (a follow, a reaction, a block) and the notification it causes
  for a local actor, in one transaction:

    * `Create` / `Update` of a Note-like → the object (`Graph.Ingest`), then the activity
    * `Announce` → an `:Announce` activity (the boost is the edge; home folds it)
    * `Like` / `EmojiReact` → an activity and a `reaction` (key `like`, `u:<emoji>` or `e:<iri>`)
    * `Follow` → a `:pending` follow; `Accept` → `:accepted`; `Reject` → removed
    * `Block` → a block
    * `Undo` → removes the activity it names, and the edge it made
    * `Delete` → a Tombstone

  Notifications are made only for a *local* recipient, once per
  (recipient, source) — a redelivered activity does not notify twice.
  """

  alias SukhiFedi.{Graph, RawStore, Snowflake}
  alias SukhiFedi.Graph.{Actor, Ingest}

  @object_types ~w(Note Article Question Page Image Video Audio Event)

  @type result :: :ok | {:ignored, atom()} | {:error, term()}

  @doc "Options: `:raw` (required, the bytes received), `:local?`, `:now`, `:raw_config`, `:followers`."
  @spec record(map(), keyword()) :: result()
  def record(%{"type" => type} = a, opts) when is_binary(type) do
    case type do
      t when t in ["Create", "Update"] -> create(a, opts)
      "Announce" -> simple(a, opts, :Announce, :reblog)
      "Like" -> reaction(a, opts)
      "EmojiReact" -> reaction(a, opts)
      "Follow" -> follow(a, opts)
      "Accept" -> accept(a)
      "Reject" -> reject(a)
      "Block" -> block(a, opts)
      "Undo" -> undo(a)
      "Delete" -> delete(a)
      _ -> {:ignored, :type}
    end
  end

  def record(_, _), do: {:ignored, :shape}

  # ------------------------------------------------------------------ Create

  # A vote arrives as a Create of a Note with a `name` (the chosen option),
  # no content, replying to the Question.
  defp create(%{"object" => %{"type" => "Note", "name" => name, "inReplyTo" => question} = object} = a, _opts)
       when is_binary(name) and not is_map_key(object, "content") do
    with actor when is_binary(actor) <- iri(a["actor"]),
         question when is_binary(question) <- iri(question),
         [[choice]] <-
           Graph.query!(
             "[:find ?c :where [?q :object/id #{lit(question)}] [?p :poll/object ?q] [?c :choice/poll ?p] [?c :choice/title #{lit(name)}]]"
           ) do
      tx = [
        %{":db/id" => -1, ":actor/id" => actor},
        %{":vote/actor" => -1, ":vote/choice" => choice}
      ]

      Graph.exclusive(fn -> with {:ok, _} <- Graph.transact(tx), do: :ok end)
    else
      _ -> {:ignored, :unknown_poll}
    end
  end

  defp create(%{"object" => %{"type" => type} = object} = a, opts) when type in @object_types do
    object = Map.put_new(object, "attributedTo", iri(a["actor"]))
    raw = :json.encode(object) |> IO.iodata_to_binary()

    with {:ok, %{id: id}} <- Ingest.object(object, Keyword.merge(opts, raw: raw)),
         :ok <- write_activity(a, :Create, object_ref: id, opts: opts) do
      notify_about_object(object, id, a, opts)
    end
  end

  defp create(%{"object" => %{"type" => type} = actor_doc}, opts) do
    if Actor.actor_type?(type),
      do: with({:ok, _} <- Actor.ingest(actor_doc, raw: Keyword.fetch!(opts, :raw)), do: :ok),
      else: {:ignored, :object_type}
  end

  defp create(_, _), do: {:ignored, :object}

  # --------------------------------------------------------- simple activity

  defp simple(a, opts, type, notification) do
    with actor when is_binary(actor) <- iri(a["actor"]),
         object when is_binary(object) <- iri(a["object"]),
         :ok <- write_activity(a, type, object_ref: object, opts: opts) do
      notify_local_author(object, notification, actor, a, opts)
    else
      _ -> {:ignored, :shape}
    end
  end

  defp reaction(a, opts) do
    with actor when is_binary(actor) <- iri(a["actor"]),
         object when is_binary(object) <- iri(a["object"]) do
      type = String.to_atom(a["type"])
      key = reaction_key(a)

      emoji = custom_emoji(a)

      extra =
        [
          compact(%{
            ":reaction/id" => a["id"],
            ":reaction/actor" => -2,
            ":reaction/object" => -3,
            ":reaction/key" => key,
            ":reaction/emoji" => if(emoji, do: -4),
            ":reaction/at" => at(a, opts)
          })
        ] ++ if(emoji, do: [emoji], else: [])

      with :ok <- write_activity(a, type, object_ref: object, opts: opts, extra: extra) do
        notify_local_author(
          object,
          if(key == "like", do: :favourite, else: :reaction),
          actor,
          a,
          opts
        )
      end
    else
      _ -> {:ignored, :shape}
    end
  end

  # The custom emoji an EmojiReact names (its `tag`), as an entity with tempid -4.
  defp custom_emoji(a) do
    a
    |> Map.get("tag", [])
    |> List.wrap()
    |> Enum.find(&(is_map(&1) and &1["type"] == "Emoji" and is_binary(&1["id"])))
    |> case do
      nil ->
        nil

      e ->
        compact(%{
          ":db/id" => -4,
          ":emoji/id" => e["id"],
          ":emoji/name" => e["name"] && String.trim(e["name"], ":"),
          ":emoji/host" => URI.parse(e["id"]).host,
          ":emoji/image-url" => get_in(e, ["icon", "url"])
        })
    end
  end

  defp compact(map), do: map |> Enum.reject(fn {_, v} -> is_nil(v) or v == "" end) |> Map.new()

  defp reaction_key(%{"type" => "Like", "content" => nil}), do: "like"
  defp reaction_key(%{"type" => "Like"} = a) when not is_map_key(a, "content"), do: "like"

  defp reaction_key(a) do
    case {a["content"], a["tag"]} do
      {c, _} when c in [nil, ""] -> "like"
      {c, [%{"id" => emoji} | _]} when is_binary(emoji) -> "e:" <> emoji <> "|" <> c
      {c, %{"id" => emoji}} when is_binary(emoji) -> "e:" <> emoji <> "|" <> c
      {c, _} -> "u:" <> normalize(c)
    end
  end

  # variation selector-16 would make ❤ and ❤️ two reactions
  defp normalize(c), do: String.replace(c, "️", "")

  # ------------------------------------------------------------------ follow

  defp follow(a, opts) do
    with actor when is_binary(actor) <- iri(a["actor"]),
         followee when is_binary(followee) <- iri(a["object"]) do
      extra = [
        %{
          ":follow/follower" => -2,
          ":follow/followee" => -3,
          ":follow/state" => ":pending",
          ":follow/activity" => -1,
          ":follow/at" => at(a, opts)
        }
      ]

      with :ok <-
             write_activity(a, :Follow,
               object_ref: followee,
               object_actor?: true,
               opts: opts,
               extra: extra
             ) do
        notify(followee, :follow, actor, a, opts)
      end
    else
      _ -> {:ignored, :shape}
    end
  end

  # Accept(Follow): the follow is named by id, or by its (follower, followee).
  defp accept(%{"object" => object, "actor" => followee}) do
    followee = iri(followee)

    with {:ok, eid} <- find_follow(object, followee) do
      with {:ok, _} <- Graph.transact([%{":db/id" => eid, ":follow/state" => ":accepted"}]),
           do: :ok
    end
  end

  defp accept(_), do: {:ignored, :shape}

  defp reject(%{"object" => object, "actor" => followee}) do
    with {:ok, eid} <- find_follow(object, iri(followee)) do
      with {:ok, _} <- Graph.transact([[":db.fn/retractEntity", eid]]), do: :ok
    end
  end

  defp reject(_), do: {:ignored, :shape}

  defp find_follow(object, followee) do
    q =
      case object do
        %{"actor" => follower} when is_binary(follower) or is_map(follower) ->
          "[:find ?f :where [?a :actor/id #{lit(iri(follower))}] [?b :actor/id #{lit(followee)}] [?f :follow/follower ?a] [?f :follow/followee ?b]]"

        id when is_binary(id) ->
          "[:find ?f :where [?x :activity/id #{lit(id)}] [?f :follow/activity ?x]]"

        %{"id" => id} when is_binary(id) ->
          "[:find ?f :where [?x :activity/id #{lit(id)}] [?f :follow/activity ?x]]"

        _ ->
          nil
      end

    case q && Graph.query!(q) do
      [[eid]] -> {:ok, eid}
      _ -> {:ignored, :unknown_follow}
    end
  end

  defp block(a, opts) do
    with actor when is_binary(actor) <- iri(a["actor"]),
         target when is_binary(target) <- iri(a["object"]) do
      extra = [%{":block/actor" => -2, ":block/target" => -3}]
      write_activity(a, :Block, object_ref: target, object_actor?: true, opts: opts, extra: extra)
    else
      _ -> {:ignored, :shape}
    end
  end

  # -------------------------------------------------------------------- undo

  defp undo(%{"object" => object, "actor" => actor}) do
    id = if is_binary(object), do: object, else: object["id"]

    case id &&
           Graph.query!(
             "[:find ?x :where [?x :activity/id #{lit(id)}] [?x :activity/actor ?a] [?a :actor/id #{lit(iri(actor))}]]"
           ) do
      [[x]] ->
        owned =
          for attr <- ~w(follow/activity),
              [e] <- Graph.query!("[:find ?e :where [?e :#{attr} #{x}]]"),
              do: e

        reactions =
          Graph.query!("[:find ?e :where [?e :reaction/id #{lit(id)}]]") |> Enum.map(&hd/1)

        blocks = block_edges(x)

        notes =
          Graph.query!("[:find ?n :where [?n :notification/source #{x}]]") |> Enum.map(&hd/1)

        tx =
          for e <- owned ++ reactions ++ blocks ++ notes ++ [x], do: [":db.fn/retractEntity", e]

        with {:ok, _} <- Graph.transact(tx), do: :ok

      _ ->
        {:ignored, :unknown_activity}
    end
  end

  defp undo(_), do: {:ignored, :shape}

  defp block_edges(x) do
    Graph.query!(
      "[:find ?b :where [#{x} :activity/type :Block] [#{x} :activity/actor ?a] [#{x} :activity/object ?t] [?b :block/actor ?a] [?b :block/target ?t]]"
    )
    |> Enum.map(&hd/1)
  end

  defp delete(%{"object" => object}) do
    case iri(object) do
      id when is_binary(id) -> with {:ok, _} <- Ingest.tombstone(id), do: :ok
      _ -> {:ignored, :shape}
    end
  end

  defp delete(_), do: {:ignored, :shape}

  # --------------------------------------------------------- activity entity

  # Tempids: -1 the activity, -2 its actor, -3 its object (an object, or an
  # actor for Follow/Block). `extra` entities refer to those.
  defp write_activity(a, type, args) do
    opts = Keyword.fetch!(args, :opts)
    object = Keyword.fetch!(args, :object_ref)
    object_attr = if args[:object_actor?], do: ":actor/id", else: ":object/id"
    raw_config = Keyword.get_lazy(opts, :raw_config, &RawStore.Config.current/0)
    actor = iri(a["actor"])

    with true <- is_binary(actor) and is_binary(a["id"]),
         {:ok, raw_attrs} <- RawStore.put("activity", Keyword.fetch!(opts, :raw), raw_config) do
      activity =
        %{
          ":db/id" => -1,
          ":activity/id" => a["id"],
          ":activity/type" => ":#{type}",
          ":activity/actor" => -2,
          ":activity/object" => -3,
          ":activity/published" => at(a, opts),
          ":activity/local?" => Keyword.get(opts, :local?, false)
        }
        |> Map.merge(Map.new(raw_attrs, fn {k, v} -> {":" <> Atom.to_string(k), v} end))

      tx =
        [
          %{":db/id" => -2, ":actor/id" => actor},
          %{":db/id" => -3, object_attr => object},
          activity
        ] ++
          Keyword.get(args, :extra, [])

      Graph.exclusive(fn ->
        with {:ok, _} <- Graph.transact(tx), do: :ok
      end)
    else
      false -> {:ignored, :no_id}
      {:error, _} = err -> err
    end
  end

  # ----------------------------------------------------------- notifications

  defp notify_local_author(object_iri, type, from, a, opts) do
    case Graph.query!(
           "[:find ?i :where [?o :object/id #{lit(object_iri)}] [?o :object/attributed-to ?u] [?u :actor/id ?i]]"
         ) do
      [[author]] -> notify(author, type, from, a, opts)
      _ -> :ok
    end
  end

  defp notify_about_object(object, id, a, opts) do
    from = iri(a["actor"])

    mentioned =
      object
      |> Map.get("tag", [])
      |> List.wrap()
      |> Enum.filter(&(is_map(&1) and &1["type"] == "Mention"))
      |> Enum.map(& &1["href"])

    parent_author =
      with parent when is_binary(parent) <- object |> Map.get("inReplyTo") |> iri(),
           [[author]] <-
             Graph.query!(
               "[:find ?i :where [?o :object/id #{lit(parent)}] [?o :object/attributed-to ?u] [?u :actor/id ?i]]"
             ) do
        author
      else
        _ -> nil
      end

    for to <- Enum.uniq(mentioned ++ List.wrap(parent_author)) do
      type = if to in mentioned, do: :mention, else: :reply
      notify(to, type, from, %{"id" => id}, opts)
    end

    :ok
  end

  # One notification per (recipient, source activity), only for a local recipient.
  defp notify(recipient, _type, from, _a, _opts) when recipient == from, do: :ok

  defp notify(recipient, type, from, a, opts) do
    source = a["id"]
    source_attr = if is_map_key(a, "type"), do: ":activity/id", else: ":object/id"

    local? =
      Graph.query!("[:find ?a :where [?a :actor/id #{lit(recipient)}] [?a :actor/local? true]]") !=
        []

    cond do
      not local? or not is_binary(source) ->
        :ok

      Graph.query!(
        "[:find ?n :where [?s #{source_attr} #{lit(source)}] [?n :notification/source ?s] [?n :notification/recipient ?r] [?r :actor/id #{lit(recipient)}]]"
      ) != [] ->
        :ok

      true ->
        at = Keyword.get_lazy(opts, :now, &Graph.now/0)

        tx = [
          %{":db/id" => -1, ":actor/id" => recipient},
          %{":db/id" => -2, ":actor/id" => from},
          %{":db/id" => -3, source_attr => source},
          %{
            ":notification/sid" =>
              Snowflake.encode(div(at, 1000), :erlang.unique_integer([:positive])),
            ":notification/recipient" => -1,
            ":notification/from" => -2,
            ":notification/type" => ":#{type}",
            ":notification/source" => -3,
            ":notification/at" => at
          }
        ]

        Graph.exclusive(fn -> with {:ok, _} <- Graph.transact(tx), do: :ok end)
    end
  end

  # ----------------------------------------------------------------- helpers

  defp at(a, opts), do: Graph.micros(a["published"]) || Keyword.get_lazy(opts, :now, &Graph.now/0)

  defp iri(v) when is_binary(v), do: v
  defp iri(%{"id" => v}) when is_binary(v), do: v
  defp iri(_), do: nil

  defp lit(s), do: SukhiFedi.Datalevin.Edn.literal(s)
end
