# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiHosi.Notes do
  @moduledoc """
  What sukhi does with posts, as one write each: a post, a like, an unlike, a boost.

  The post and the line that tells the relay about it are written together, so there is never a
  post the relay will not hear of, nor a line for a post that is not there. No counter is kept:
  likes are the values of `object/liked-by`, and the count is how many there are.
  """

  alias SukhiHosi.{Actors, Notifications, Store}

  @doc """
  The ops of an object, so that a local post and an incoming one are made the same way.
  `author` is a ref (an id, or `[:tmp, n]`); the object is `[:tmp, n]`. A post with no parent is
  the root of its own thread.
  """
  def object_ops(n, author, iri, html, opts) do
    root = if parent = opts[:in_reply_to], do: root_of(opts[:db], parent), else: [:ref, [:tmp, n]]

    [
      [:create, [:tmp, n], :"object/id", iri],
      [:create, [:tmp, n], :"object/attributed-to", [:ref, author]],
      [:create, [:tmp, n], :"object/published", Keyword.get(opts, :published) || Store.now_us()],
      [:create, [:tmp, n], :"object/local?", Keyword.get(opts, :local?, true)],
      [:create, [:tmp, n], :"object/visibility", Keyword.get(opts, :visibility, :public)],
      [:create, [:tmp, n], :"object/content-html", html],
      [:create, [:tmp, n], :"object/root", root]
    ] ++
      if(opts[:in_reply_to], do: [[:create, [:tmp, n], :"object/in-reply-to", [:ref, opts[:in_reply_to]]]], else: []) ++
      for(tag <- Keyword.get(opts, :tags, []), do: [:create, [:tmp, n], :"object/tags", String.downcase(tag)]) ++
      for(who <- Enum.uniq(Keyword.get(opts, :mentions, [])), do: [:create, [:tmp, n], :"object/mentions", [:ref, who]])
  end

  defp root_of(db, parent) do
    [e] = Store.entities(db, [parent])
    [:ref, e |> Map.fetch!(:"object/root") |> hd()]
  end

  @doc """
  A post by `author`, and its Create for the relay. `{:error, :duplicate}` if the IRI is taken.
  `mentions: [account]` names who it mentions; those who are accounts here are told, in the same write.
  """
  def post(db, author, iri, html, opts \\ []) do
    outbox = [
      [:create, [:tmp, 2], :"outbox/kind", "Create"],
      [:create, [:tmp, 2], :"outbox/object", [:ref, [:tmp, 1]]],
      [:create, [:tmp, 2], :"outbox/actor", [:ref, author]]
    ]

    told = Notifications.mention_ops(db, 3, [:tmp, 1], iri, author, Keyword.get(opts, :mentions, []))

    case Hosi.write(db, object_ops(1, author, iri, html, Keyword.put(opts, :db, db)) ++ outbox ++ told) do
      {:ok, %{temps: temps}} -> {:ok, Map.new(temps, fn [n, id] -> {n, id} end)[1]}
      {:error, {:app, _, _}} -> {:error, :duplicate}
    end
  end

  @doc "`actor` likes `note`. Twice is once: the second changes nothing and tells the relay nothing."
  def like(db, note, actor) do
    ops = [
      [:create, note, :"object/liked-by", [:ref, actor]],
      [:create, [:tmp, 1], :"outbox/kind", "Like"],
      [:create, [:tmp, 1], :"outbox/object", [:ref, note]],
      [:create, [:tmp, 1], :"outbox/actor", [:ref, actor]]
    ] ++ Notifications.ops(db, 2, :like, note, actor)

    case Hosi.write(db, ops, when: [[:lacks, note, :"object/liked-by", actor]]) do
      {:ok, _} -> :ok
      {:error, {:app, :conflict, _}} -> :already
    end
  end

  def unlike(db, note, actor) do
    ops = [
      [:delete, note, :"object/liked-by", [:ref, actor]],
      [:create, [:tmp, 1], :"outbox/kind", "Undo"],
      [:create, [:tmp, 1], :"outbox/object", [:ref, note]],
      [:create, [:tmp, 1], :"outbox/actor", [:ref, actor]]
    ] ++ Notifications.undo_ops(db, :like, note, actor)

    case Hosi.write(db, ops, when: [[:holds, note, :"object/liked-by", actor]]) do
      {:ok, _} -> :ok
      {:error, {:app, :conflict, _}} -> :not_liked
    end
  end

  @doc """
  `actor` boosts `note`. The activity's own IRI is made from the two, and an IRI is an identity,
  so a second boost is refused by the store: there is no check to forget.
  """
  def boost(db, note, actor, opts \\ []) do
    iri = boost_iri(db, note, actor)

    ops = [
      [:create, [:tmp, 1], :"activity/id", iri],
      [:create, [:tmp, 1], :"activity/type", :Announce],
      [:create, [:tmp, 1], :"activity/actor", [:ref, actor]],
      [:create, [:tmp, 1], :"activity/object", [:ref, note]],
      [:create, [:tmp, 1], :"activity/published", Keyword.get(opts, :published) || Store.now_us()],
      [:create, [:tmp, 2], :"outbox/kind", "Announce"],
      [:create, [:tmp, 2], :"outbox/object", [:ref, note]],
      [:create, [:tmp, 2], :"outbox/actor", [:ref, actor]]
    ] ++ Notifications.ops(db, 3, :reblog, note, actor)

    case Hosi.write(db, ops) do
      {:ok, _} -> :ok
      {:error, {:app, _, _}} -> :already
    end
  end

  @doc """
  `actor` takes back their boost of `note`. The boost, the notification it made and nothing else go;
  the relay is told (`UndoAnnounce`). `:not_boosted` when there is none (so taking back twice is once).
  The facts of the boost stay in the log, and boosting again makes a new one.
  """
  def unboost(db, note, actor) do
    case Store.lookup(db, :"activity/id", boost_iri(db, note, actor)) do
      nil ->
        :not_boosted

      boost ->
        ops =
          Store.retract_ops(db, boost) ++
            [
              [:create, [:tmp, 1], :"outbox/kind", "UndoAnnounce"],
              [:create, [:tmp, 1], :"outbox/object", [:ref, note]],
              [:create, [:tmp, 1], :"outbox/actor", [:ref, actor]]
            ] ++ Notifications.undo_ops(db, :reblog, note, actor)

        case Hosi.write(db, ops, when: [[:holds, boost, :"activity/actor", actor]]) do
          {:ok, _} -> :ok
          {:error, {:app, :conflict, _}} -> :not_boosted
        end
    end
  end

  @doc """
  `actor` deletes their post `note`: the post, the boosts of it and the notifications about it go in
  one write, and the relay is told (`Delete`, carrying the post's IRI: the post will not be there to
  ask). `{:error, :forbidden}` if it is someone else's, `{:error, :not_found}` if there is none (so
  deleting twice is once). What others wrote in answer stays, and still points at the id.

  This is a delete, not an erase: the facts stay in the log. A person's whole account is taken off
  the disk by `Accounts.erase`, after the relay has told everyone (see `AccountClosing`).
  """
  def delete(db, note, actor) do
    with {:ok, ops} <- delete_ops(db, note, actor) do
      case Hosi.write(db, ops, when: [[:holds, note, :"object/attributed-to", actor]]) do
        {:ok, _} -> :ok
        {:error, {:app, :conflict, _}} -> {:error, :not_found}
      end
    end
  end

  @doc """
  The ops of `delete/3`, to be written by the caller (`{:ok, ops}`, or the same `{:error, _}`).
  There is no `when` here: whoever writes decides whether the post is still theirs. `AccountClosing`
  writes many of these in one `Hosi.write_many`, which takes no conditions.
  """
  def delete_ops(db, note, actor) do
    with {:ok, e} <- owned(db, note, actor) do
      iri = e |> Map.fetch!(:"object/id") |> hd()
      [me] = Store.entities(db, [actor])
      attached = fn attr -> db |> Store.rows("[:find ?x :in $ ?n :where [?x #{attr} ?n]]", [[:scalar, note]]) |> List.flatten() end

      {:ok,
       Store.retract_ops_many(db, [note | attached.(":activity/object") ++ attached.(":notification/note")]) ++
         if(note in Map.get(me, :"actor/pinned", []), do: [[:delete, actor, :"actor/pinned", [:ref, note]]], else: []) ++
         outbox_ops("Delete", note, actor, iri)}
    end
  end

  @doc "`actor` features their post on their profile. The relay is told (`Add`). `:already` if it is."
  def pin(db, note, actor) do
    with {:ok, e} <- owned(db, note, actor) do
      ops = [[:create, actor, :"actor/pinned", [:ref, note]]] ++ outbox_ops("Add", note, actor, hd(e[:"object/id"]))

      case Hosi.write(db, ops, when: [[:lacks, actor, :"actor/pinned", note]]) do
        {:ok, _} -> :ok
        {:error, {:app, :conflict, _}} -> :already
      end
    end
  end

  @doc "Take it off their profile. The relay is told (`Remove`). `:not_pinned` if it was not there."
  def unpin(db, note, actor) do
    with {:ok, e} <- owned(db, note, actor) do
      ops = [[:delete, actor, :"actor/pinned", [:ref, note]]] ++ outbox_ops("Remove", note, actor, hd(e[:"object/id"]))

      case Hosi.write(db, ops, when: [[:holds, actor, :"actor/pinned", note]]) do
        {:ok, _} -> :ok
        {:error, {:app, :conflict, _}} -> :not_pinned
      end
    end
  end

  @doc "The posts `actor` features, as ids."
  def pinned(db, actor) do
    [e] = Store.entities(db, [actor])
    Map.get(e, :"actor/pinned", [])
  end

  # the post, if it is there and is theirs
  defp owned(db, note, actor) do
    case Store.entities(db, [note]) do
      [%{"object/id": [_ | _], "object/attributed-to": [^actor]} = e] -> {:ok, e}
      [%{"object/id": [_ | _]}] -> {:error, :forbidden}
      _ -> {:error, :not_found}
    end
  end

  # a line for the relay about `note` that names it by its IRI, so it can still be told when it is gone
  defp outbox_ops(kind, note, actor, iri) do
    [
      [:create, [:tmp, 1], :"outbox/kind", kind],
      [:create, [:tmp, 1], :"outbox/object", [:ref, note]],
      [:create, [:tmp, 1], :"outbox/actor", [:ref, actor]],
      [:create, [:tmp, 1], :"outbox/ap-id", iri]
    ]
  end

  defp boost_iri(db, note, actor) do
    [n] = Store.entities(db, [note])
    Actors.iri(db, actor) <> "#boost/" <> (n |> Map.fetch!(:"object/id") |> hd())
  end

  def get(db, id) do
    [e] = Store.entities(db, [id])
    first = fn k -> e |> Map.get(k, []) |> List.first() end

    %{
      id: id,
      iri: first.(:"object/id"),
      html: first.(:"object/content-html"),
      author: first.(:"object/attributed-to"),
      published: first.(:"object/published"),
      visibility: first.(:"object/visibility"),
      root: first.(:"object/root"),
      tags: e |> Map.get(:"object/tags", []) |> Enum.sort(),
      likes: length(Map.get(e, :"object/liked-by", []))
    }
  end

  def find(db, iri), do: Store.lookup(db, :"object/id", iri)
end
