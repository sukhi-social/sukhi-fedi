# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Graph.Local do
  @moduledoc """
  What local users do, copied into the graph.

  The inbox door has `SukhiFedi.Graph.Mirror`; this is the other door. It
  never edits a code path that changes the relational store: it *follows* it.

    * **The outbox.** Every federating local action already writes an `outbox`
      row in the same transaction as the action. This process tails that table
      by id, says each row in ActivityPub (`SukhiFedi.Graph.Project`) and hands
      it to `SukhiFedi.Graph.Activity` — the one door. The cursor lives in the
      graph (`sync/outbox`), so it moves with the data it describes. A row may
      be handled twice (a crash between the write and the cursor); every write
      is an upsert by id, so that is harmless.
    * **Hooks** for what never federates — bookmarks, lists, votes on a local
      poll, a follow between two local accounts. `changed/2` is a cast; the
      handler re-reads the row and *sets the graph to match*, so a hook lost or
      repeated does no damage.

  A row that fails for a reason that will not go away (a deleted note) is
  skipped; one that fails for a transient reason (the graph is down) is retried
  on the next tick, up to `@attempts` times, and the cursor does not pass it.

  The first run starts at the newest outbox row: the history before the graph
  was switched on is the existing-data backfill (TODO.md), not this process's job.
  """

  use GenServer

  import Ecto.Query

  require Logger

  alias SukhiFedi.{Graph, Repo}
  alias SukhiFedi.Graph.{Actor, Activity, Project}

  alias SukhiFedi.Schema.{
    Account,
    Bookmark,
    Follow,
    List,
    Note,
    OutboxEvent,
    PinnedNote,
    Poll,
    PollVote
  }

  @batch 200
  @attempts 5
  @tick :timer.seconds(2)
  @sync "outbox"

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Tell the graph that something which emits no outbox row changed. `kind`:
  `{:bookmark, account_id, note_id}`, `{:list, list_id}`,
  `{:votes, poll_id, account_id}`, `{:follow, follow_id}`. A no-op while the
  graph is off.
  """
  @spec changed(tuple()) :: :ok
  def changed(kind) when is_tuple(kind) do
    if Graph.enabled?() and Process.whereis(__MODULE__),
      do: GenServer.cast(__MODULE__, {:changed, kind})

    :ok
  end

  @doc "Handle everything after the cursor now (what each tick does; tests call it)."
  @spec drain() :: {:ok, non_neg_integer()}
  def drain, do: GenServer.call(__MODULE__, :drain, :infinity)

  # ------------------------------------------------------------------ server

  @impl true
  def init(opts) do
    # `ticking: false` leaves the work to `drain/0` (tests).
    if Keyword.get(opts, :ticking, true), do: send(self(), :tick)

    {:ok,
     %{
       cursor: nil,
       tries: %{},
       interval: Keyword.get(opts, :interval, @tick),
       ticking: Keyword.get(opts, :ticking, true)
     }}
  end

  @impl true
  def handle_info(:tick, state) do
    {_n, state} = step(state)
    Process.send_after(self(), :tick, state.interval)
    {:noreply, state}
  end

  @impl true
  def handle_call(:drain, _from, state) do
    {n, state} = step(state)
    {:reply, {:ok, n}, state}
  end

  @impl true
  def handle_cast({:changed, kind}, state) do
    guard("hook #{inspect(kind)}", fn -> sync(kind) end)
    {:noreply, state}
  end

  defp step(state) do
    case cursor(state) do
      {:ok, cursor} ->
        rows =
          Repo.all(from(o in OutboxEvent, where: o.id > ^cursor, order_by: o.id, limit: ^@batch))

        {last, tries, handled} = Enum.reduce_while(rows, {cursor, state.tries, 0}, &advance/2)
        if last != cursor, do: put_cursor(last)
        {handled, %{state | cursor: last, tries: tries}}

      :error ->
        {0, state}
    end
  rescue
    e ->
      Logger.warning("graph local: #{Exception.message(e)}")
      {0, state}
  end

  defp advance(row, {cursor, tries, n}) do
    case guard("outbox #{row.id} #{row.subject}", fn ->
           handle(row.subject, row.payload, row.inserted_at)
         end) do
      {:error, reason} ->
        count = Map.get(tries, row.id, 0) + 1

        if count >= @attempts do
          Logger.warning("graph local: giving up on outbox #{row.id}: #{inspect(reason)}")
          {:cont, {row.id, Map.delete(tries, row.id), n}}
        else
          {:halt, {cursor, Map.put(tries, row.id, count), n}}
        end

      _ ->
        {:cont, {row.id, Map.delete(tries, row.id), n + 1}}
    end
  end

  defp guard(what, fun) do
    fun.()
  rescue
    e ->
      Logger.warning("graph local: #{what} raised #{Exception.message(e)}")
      {:error, e}
  catch
    kind, reason ->
      Logger.warning("graph local: #{what} #{kind} #{inspect(reason)}")
      {:error, reason}
  end

  # The cursor is read once; `nil` means "no graph record yet" and starts at the tail.
  defp cursor(%{cursor: c}) when is_integer(c), do: {:ok, c}

  defp cursor(_) do
    case Graph.query("[:find ?c :where [?s :sync/name #{lit(@sync)}] [?s :sync/cursor ?c]]") do
      {:ok, [[c]]} ->
        {:ok, c}

      {:ok, []} ->
        tail = Repo.one(from(o in OutboxEvent, select: max(o.id))) || 0
        put_cursor(tail)
        {:ok, tail}

      _ ->
        :error
    end
  end

  defp put_cursor(c),
    do: Graph.exclusive(fn -> Graph.transact([%{":sync/name" => @sync, ":sync/cursor" => c}]) end)

  # ------------------------------------------------------------ outbox rows

  @doc """
  One outbox row, written into the graph. `payload` has string keys; `at` is
  when the row was written. Returns `:ok | {:ignored, _} | {:error, _}`.
  """
  @spec handle(String.t(), map(), DateTime.t() | NaiveDateTime.t()) ::
          :ok | {:ignored, atom()} | {:error, term()}
  def handle("sns.outbox.note." <> op, %{"note_id" => id}, at)
      when op in ["created", "updated"] do
    kind = if op == "created", do: "Create", else: "Update"

    with %Note{} = note <- note_with_refs(id),
         %Account{} = author <- Repo.get(Account, note.account_id),
         true <- note.ap_id != nil and Project.actor_iri(author) != nil do
      ensure_local(author)

      note
      |> then(&Project.note_activity(kind, &1, author, &1.media, &1.poll, utc(at)))
      |> record(author)
    else
      _ -> {:ignored, :gone}
    end
  end

  def handle("sns.outbox.note.deleted", %{"ap_id" => ap_id, "account_id" => aid}, _at) do
    with %Account{} = author <- Repo.get(Account, aid) do
      ap_id |> Project.delete(author) |> record(author)
    else
      _ -> {:ignored, :gone}
    end
  end

  def handle("sns.outbox." <> kind, %{"reaction_id" => rid, "account_id" => aid} = p, at)
      when kind in ["like.created", "reaction.created"] do
    with %Account{} = actor <- Repo.get(Account, aid), ap when is_binary(ap) <- p["note_ap_id"] do
      ensure_local(actor)

      %{id: rid}
      |> Project.reaction(actor, ap, p["emoji"], iso(at))
      |> record(actor)
    else
      _ -> {:ignored, :gone}
    end
  end

  def handle("sns.outbox." <> kind, %{"reaction_id" => rid, "account_id" => aid}, at)
      when kind in ["like.undone", "reaction.undone"] do
    undo(aid, &Project.reaction_id(&1, rid), at)
  end

  def handle(
        "sns.outbox.announce.created",
        %{"boost_id" => bid, "account_id" => aid, "note_ap_id" => ap},
        at
      )
      when is_binary(ap) do
    with %Account{} = actor <- Repo.get(Account, aid) do
      ensure_local(actor)
      bid |> Project.announce(actor, ap, iso(at)) |> record(actor)
    else
      _ -> {:ignored, :gone}
    end
  end

  def handle("sns.outbox.announce.undone", %{"boost_id" => bid, "account_id" => aid}, at),
    do: undo(aid, &Project.announce_id(&1, bid), at)

  def handle(
        "sns.outbox.follow.requested",
        %{"follow_id" => id, "follower_uri" => follower, "followee_id" => fid},
        at
      ) do
    with %Account{} = followee <- Repo.get(Account, fid),
         followee_iri when is_binary(followee_iri) <- Project.actor_iri(followee) do
      local_actor_by_uri(follower) |> ensure_local()

      id |> Project.follow(follower, followee_iri, iso(at)) |> record_as(nil)
    else
      _ -> {:ignored, :gone}
    end
  end

  def handle("sns.outbox.follow.undone", %{"follow_id" => id, "follower_uri" => follower}, at) do
    follower |> Project.follow_id(id) |> Project.undo(follower, iso(at)) |> record_as(nil)
  end

  def handle("sns.outbox.add.created", %{"account_id" => aid, "note_ap_id" => ap} = p, _at),
    do: pin(aid, ap, p["pinned_id"], true)

  def handle("sns.outbox.remove.created", %{"account_id" => aid, "note_ap_id" => ap}, _at),
    do: pin(aid, ap, nil, false)

  def handle("sns.outbox.actor.updated", %{"account_id" => aid}, _at) do
    case Repo.get(Account, aid) do
      %Account{domain: nil} = a -> upsert_local(a)
      _ -> {:ignored, :remote}
    end
  end

  # votes are synced by hook (they cover local polls too); the rest are not graph state.
  def handle(_subject, _payload, _at), do: {:ignored, :subject}

  defp undo(aid, id_for, at) do
    with %Account{} = actor <- Repo.get(Account, aid),
         iri when is_binary(iri) <- Project.actor_iri(actor) do
      actor |> id_for.() |> Project.undo(iri, iso(at)) |> record(actor)
    else
      _ -> {:ignored, :gone}
    end
  end

  defp note_with_refs(id) do
    case Repo.get(Note, id) do
      nil -> nil
      note -> Repo.preload(note, [:media, poll: :options])
    end
  end

  # ------------------------------------------------------------- state hooks

  @doc """
  Set the graph to match one row of the relational store (what `changed/1`
  asks for). Idempotent: run it twice, or after a missed call, and the graph
  still ends up equal to the row.
  """
  @spec sync(tuple()) :: :ok | {:ignored, atom()} | {:error, term()}
  def sync({:bookmark, account_id, note_id}) do
    with %Account{} = actor <- Repo.get(Account, account_id),
         %Note{ap_id: ap} when is_binary(ap) <- Repo.get(Note, note_id) do
      ensure_local(actor)

      exists? =
        Repo.exists?(
          from(b in Bookmark, where: b.account_id == ^account_id and b.note_id == ^note_id)
        )

      edge("bookmark", actor, ap, exists?, %{":bookmark/at" => Graph.now()})
    else
      _ -> {:ignored, :gone}
    end
  end

  def sync({:list, id}) do
    case Repo.get(List, id) do
      nil -> retract_list(id)
      list -> write_list(Repo.preload(list, :accounts))
    end
  end

  def sync({:votes, poll_id, account_id}) do
    with %Poll{} = poll <- Repo.get(Poll, poll_id),
         %Account{} = voter <- Repo.get(Account, account_id),
         %Note{ap_id: ap} when is_binary(ap) <- Repo.get(Note, poll.note_id) do
      ensure_local(voter)

      titles =
        from(v in PollVote,
          join: o in assoc(v, :option),
          where: v.poll_id == ^poll_id and v.account_id == ^account_id,
          select: o.title
        )
        |> Repo.all()

      write_votes(Project.actor_iri(voter), ap, titles)
    else
      _ -> {:ignored, :gone}
    end
  end

  # A follow whose row is gone is undone (`follower_uri` names its activity).
  def sync({:follow, id, follower_uri}) do
    case Repo.get(Follow, id) do
      nil ->
        follower_uri
        |> Project.follow_id(id)
        |> Project.undo(follower_uri, iso(DateTime.utc_now()))
        |> record_as(nil)

      %Follow{} = f ->
        sync_follow(f)
    end
  end

  def sync(_), do: {:ignored, :kind}

  defp sync_follow(f) do
    with %Account{} = followee <- Repo.get(Account, f.followee_id),
         followee_iri when is_binary(followee_iri) <- Project.actor_iri(followee) do
      local_actor_by_uri(f.follower_uri) |> ensure_local()
      ensure_local(followee)
      at = f.created_at |> utc() |> DateTime.to_iso8601()
      follow = Project.follow(f.id, f.follower_uri, followee_iri, at)

      with :ok <- record_as(follow, nil) do
        if f.state == "accepted" do
          accept = %{
            "id" => follow["id"] <> "/accept",
            "type" => "Accept",
            "actor" => followee_iri,
            "object" => follow["id"]
          }

          record_as(accept, nil)
        else
          :ok
        end
      end
    else
      _ -> {:ignored, :gone}
    end
  end

  # ----------------------------------------------------------- graph writes

  # One edge between an actor and a note: set when `on?`, retract otherwise.
  # `ns` is the attribute namespace; the pair is the identity (`<ns>/uniq`).
  defp edge(ns, actor, note_ap_id, on?, extra) do
    actor_iri = Project.actor_iri(actor)

    Graph.exclusive(fn ->
      found =
        Graph.query!(
          "[:find ?e :where [?a :actor/id #{lit(actor_iri)}] [?o :object/id #{lit(note_ap_id)}] [?e :#{ns}/actor ?a] [?e :#{ns}/object ?o]]"
        )

      cond do
        on? ->
          tx = [
            %{":db/id" => -1, ":actor/id" => actor_iri},
            %{":db/id" => -2, ":object/id" => note_ap_id},
            Map.merge(%{":#{ns}/actor" => -1, ":#{ns}/object" => -2}, extra)
          ]

          with {:ok, _} <- Graph.transact(tx), do: :ok

        found == [] ->
          :ok

        true ->
          with {:ok, _} <- Graph.transact(for [e] <- found, do: [":db.fn/retractEntity", e]),
               do: :ok
      end
    end)
  end

  defp pin(aid, note_ap_id, pos, on?) do
    with %Account{} = actor <- Repo.get(Account, aid), true <- is_binary(note_ap_id) do
      ensure_local(actor)
      edge("pin", actor, note_ap_id, on?, %{":pin/pos" => pin_pos(pos, aid, note_ap_id)})
    else
      _ -> {:ignored, :gone}
    end
  end

  defp pin_pos(pinned_id, _, _) when is_integer(pinned_id), do: pinned_id

  defp pin_pos(_, aid, ap),
    do:
      Repo.one(
        from(p in PinnedNote,
          join: n in Note,
          on: n.id == p.note_id,
          where: p.account_id == ^aid and n.ap_id == ^ap,
          select: p.position
        )
      ) || 0

  # A list is set whole: title, owner and members, from the row.
  defp write_list(%List{} = list) do
    owner = Repo.get(Account, list.account_id)
    members = Enum.filter(list.accounts, &(Project.actor_iri(&1) != nil))
    ensure_local(owner)
    Enum.each(members, &ensure_stub/1)

    Graph.exclusive(fn ->
      base = [
        %{":db/id" => -1, ":actor/id" => Project.actor_iri(owner)},
        %{":list/sid" => list.id, ":list/owner" => -1, ":list/title" => list.title}
      ]

      with {:ok, _} <- Graph.transact(base),
           [[eid]] <- Graph.query!("[:find ?l :where [?l :list/sid #{list.id}]]"),
           {:ok, _} <- Graph.transact([[":db.fn/retractAttribute", eid, ":list/members"]]) do
        tx =
          members
          |> Enum.with_index(1)
          |> Enum.flat_map(fn {m, i} ->
            [%{":db/id" => -i, ":actor/id" => Project.actor_iri(m)}]
          end)
          |> then(fn stubs ->
            if stubs == [],
              do: [],
              else:
                stubs ++
                  [%{":db/id" => eid, ":list/members" => Enum.map(1..length(members), &(-&1))}]
          end)

        if tx == [], do: :ok, else: with({:ok, _} <- Graph.transact(tx), do: :ok)
      else
        {:error, _} = err -> err
        _ -> {:error, :list_missing}
      end
    end)
  end

  defp retract_list(id) do
    Graph.exclusive(fn ->
      case Graph.query!("[:find ?l :where [?l :list/sid #{id}]]") do
        [[eid]] -> with {:ok, _} <- Graph.transact([[":db.fn/retractEntity", eid]]), do: :ok
        [] -> :ok
      end
    end)
  end

  # The actor's votes on one Question, set to `titles`.
  defp write_votes(actor_iri, question_ap_id, titles) do
    Graph.exclusive(fn ->
      choices =
        Graph.query!(
          "[:find ?c ?t :where [?q :object/id #{lit(question_ap_id)}] [?p :poll/object ?q] [?c :choice/poll ?p] [?c :choice/title ?t]]"
        )

      old =
        Graph.query!(
          "[:find ?v :where [?a :actor/id #{lit(actor_iri)}] [?q :object/id #{lit(question_ap_id)}] [?p :poll/object ?q] [?c :choice/poll ?p] [?v :vote/actor ?a] [?v :vote/choice ?c]]"
        )

      chosen = for [c, t] <- choices, t in titles, do: c

      with {:ok, _} <- Graph.transact(for([v] <- old, do: [":db.fn/retractEntity", v])),
           {:ok, _} <-
             Graph.transact(
               if(chosen == [],
                 do: [],
                 else:
                   [%{":db/id" => -1, ":actor/id" => actor_iri}] ++
                     for(c <- chosen, do: %{":vote/actor" => -1, ":vote/choice" => c})
               )
             ) do
        :ok
      end
    end)
  end

  # ----------------------------------------------------------------- actors

  defp upsert_local(%Account{} = a) do
    with {:ok, _} <-
           Actor.upsert_local(%{
             iri: Project.actor_iri(a),
             username: a.username,
             name: a.display_name,
             summary: a.summary,
             sid: a.id,
             admin?: a.is_admin
           }) do
      Process.put({__MODULE__, :known, a.id}, true)
      :ok
    end
  end

  # A local author is written once per process; `actor.updated` rewrites it.
  defp ensure_local(%Account{domain: nil, id: id} = a) do
    unless Process.get({__MODULE__, :known, id}), do: upsert_local(a)
    :ok
  end

  defp ensure_local(_), do: :ok

  defp ensure_stub(%Account{domain: nil} = a), do: ensure_local(a)

  defp ensure_stub(%Account{} = a),
    do: Graph.exclusive(fn -> Graph.transact([%{":actor/id" => Project.actor_iri(a)}]) end)

  defp local_actor_by_uri(uri) do
    with %URI{path: "/users/" <> name} <- URI.parse(uri),
         %Account{domain: nil} = a <-
           Repo.one(from(a in Account, where: a.username == ^name and is_nil(a.domain))) do
      a
    else
      _ -> nil
    end
  end

  # ---------------------------------------------------------------- helpers

  defp record(activity, %Account{} = actor), do: record_as(activity, Project.followers(actor))

  # `followers`: the author's followers collection, so the audience reads as a visibility.
  defp record_as(activity, followers) do
    raw = activity |> :json.encode() |> IO.iodata_to_binary()
    opts = [raw: raw, local?: true] ++ if(followers, do: [followers: followers], else: [])
    Activity.record(activity, opts)
  end

  defp utc(%DateTime{} = dt), do: dt
  defp utc(%NaiveDateTime{} = dt), do: DateTime.from_naive!(dt, "Etc/UTC")
  defp iso(at), do: at |> utc() |> DateTime.to_iso8601()

  defp lit(s), do: SukhiFedi.Datalevin.Edn.literal(s)
end
