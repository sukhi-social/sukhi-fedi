# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Maintenance.RebuildFromArchive do
  @moduledoc """
  Backfill existing remote notes from the raw inbound archive in rustfs.

  Some fields were historically dropped on ingest and only fixed going
  forward: the content warning (AP `summary` → `cw`, fixed v0.2.4), the
  publish time (AP `published` → `created_at`, fixed v0.2.2), and the
  media `attachment` (images / video, fixed v0.2.22). Notes mirrored
  before those fixes still show no spoiler, a fetch-time date, and no
  images. The bytes the remote signed are kept verbatim in the `inbound`
  bucket (`SukhiFedi.Federation.InboundArchive`), so we can recover the
  originals without hitting the network — the archive is the system of
  record, and replaying it is exactly what it's for.

  The `inbound_events` index keys on the *activity* id, not the inner
  note's id, so we walk every archived `Create` / `Update`, decompress
  the body, pull the embedded note, and match it to a local row by
  `ap_id`. We only ever set `cw`, `created_at`, and `emojis`, and only
  when the archive has a value that differs — content and everything else
  were captured correctly at ingest and are left untouched. The numeric
  id stays put, so reactions / boosts / threading are unaffected.

  Run on the live gateway (needs its Repo + rustfs credentials):

      bin/sukhi_fedi rpc 'SukhiFedi.Maintenance.RebuildFromArchive.run(:dry_run)'
      bin/sukhi_fedi rpc 'SukhiFedi.Maintenance.RebuildFromArchive.run(:execute)'
  """

  import Ecto.Query
  require Logger

  alias SukhiFedi.AP.{Emojis, Instructions, MediaIngest, Published}
  alias SukhiFedi.Maintenance.Progress
  alias SukhiFedi.{Polls, Repo}
  alias SukhiFedi.Schema.{InboundEvent, Note}

  @note_activities ~w(Create Update)

  @spec run(:dry_run | :execute) :: map()
  def run(mode \\ :dry_run) do
    # Recreate notes lost from the DB first, so the field/media/boost
    # passes below see them too.
    notes = recreate_notes(mode)

    events = note_events()
    Logger.info("rebuild_from_archive: #{length(events)} Create/Update event(s), mode=#{mode}")

    # Only :execute is a long write run worth reporting; a dry run is a
    # read-only pass and stays out of the admin page.
    summary =
      case mode do
        :execute ->
          Progress.track("rebuild_from_archive", mode, length(events), "replaying", fn run ->
            {results, run} = Progress.map(run, events, &replay_event(&1, mode), &elem(&1, 0))
            {summarize(notes, results, mode), run}
          end)

        :dry_run ->
          summarize(notes, Enum.map(events, &replay_event(&1, mode)), mode)
      end

    Logger.info("rebuild_from_archive done: #{inspect(summary)}")
    summary
  end

  # One archived Create/Update → the three passes. A note that cannot be
  # read back out of the archive reports `{:error, :error, :error}`, which
  # `Progress` counts as one failed item.
  defp replay_event(ev, mode) do
    case fetch_inner_note(ev) do
      {:ok, note} ->
        {rebuild_note(note, mode), backfill_media(note, mode), backfill_poll(note, mode)}

      {:error, reason} ->
        Logger.warning("  skip #{ev.object_key}: #{inspect(reason)}")
        {:error, :error, :error}
    end
  end

  defp summarize(notes, results, mode) do
    %{
      notes: notes,
      fields: tally(Enum.map(results, &elem(&1, 0))),
      media: tally(Enum.map(results, &elem(&1, 1))),
      polls: tally(Enum.map(results, &elem(&1, 2))),
      boosts: backfill_boosts(mode),
      mode: mode
    }
  end

  @doc """
  Recreate one actor's missing notes from its own archived `Create`s.

  Targeted sibling of `run/1`. The outbox a peer serves is not the whole
  story: Iceshrimp (and Misskey-family servers generally) omit
  followers-only posts from it, so an outbox backfill can never see them.
  Those posts *were* delivered to our inbox (we follow the author) and are
  in the inbound archive, so replaying this actor's slice is how the
  backfill recovers them.

  `:limit` bounds the S3 reads (newest first). A `Delete` from the same
  actor overrides — a post the author removed is not resurrected. `:dry_run`
  only counts.

      SukhiFedi.Maintenance.RebuildFromArchive.recreate_for_actor(uri, :execute)
  """
  @spec recreate_for_actor(String.t(), :dry_run | :execute, keyword()) :: map()
  def recreate_for_actor(actor_uri, mode \\ :execute, opts \\ []) when is_binary(actor_uri) do
    limit = Keyword.get(opts, :limit, 300)
    deleted = deleted_ap_ids_for(actor_uri)

    from(e in InboundEvent,
      where: e.activity_type == "Create" and e.actor_uri == ^actor_uri,
      order_by: [desc: e.received_at],
      limit: ^limit
    )
    |> Repo.all()
    |> Enum.map(&recreate_one(&1, deleted, mode))
    |> tally()
  end

  defp recreate_one(ev, deleted, mode) do
    case fetch_activity(ev) do
      {:ok, %{"object" => obj} = activity} ->
        ap_id = object_ap_id(obj)

        cond do
          not is_binary(ap_id) ->
            :no_object_id

          MapSet.member?(deleted, ap_id) ->
            :deleted

          note_present?(ap_id) ->
            :present

          mode == :dry_run ->
            :would_recreate

          true ->
            Instructions.reingest_for_rebuild(activity)
            :recreated
        end

      {:ok, _} ->
        :no_object_id

      {:error, reason} ->
        Logger.warning("  skip recreate #{ev.object_key}: #{inspect(reason)}")
        :error
    end
  end

  # Per-note indexed lookup — the targeted path walks one actor's slice, so
  # loading every remote ap_id into a MapSet (what `run/1` does for its
  # 40k-event sweep) would cost more than it saves.
  defp note_present?(ap_id) do
    Repo.exists?(from(n in Note, where: n.ap_id == ^ap_id))
  end

  # `Delete`s *by this actor*. A deletion is signed by the author, so
  # scoping to the same actor is both correct and far cheaper than
  # downloading every Delete in the archive.
  defp deleted_ap_ids_for(actor_uri) do
    from(e in InboundEvent,
      where: e.activity_type == "Delete" and e.actor_uri == ^actor_uri
    )
    |> Repo.all()
    |> Enum.flat_map(fn ev ->
      case fetch_activity(ev) do
        {:ok, %{"object" => obj}} -> List.wrap(object_ap_id(obj))
        _ -> []
      end
    end)
    |> MapSet.new()
  end

  @doc """
  Poll-only variant of `run/1`: sync every remote poll to its newest
  archived `Question`, touching nothing else (no note recreation, media or
  boost passes). A poll gains an `Update` on every vote, so we take each
  note's *latest* snapshot — create the poll if the note has none, refresh
  its cached tallies if it already does. Only the newest event per note
  acts (a `seen` set drops the older refreshes).

      bin/sukhi_fedi eval 'SukhiFedi.Maintenance.RebuildFromArchive.run_polls(:dry_run)'
      bin/sukhi_fedi eval 'SukhiFedi.Maintenance.RebuildFromArchive.run_polls(:execute)'
  """
  @spec run_polls(:dry_run | :execute) :: map()
  def run_polls(mode \\ :dry_run) do
    events = note_events() |> Enum.reverse()
    Logger.info("rebuild_from_archive run_polls: #{length(events)} event(s), mode=#{mode}")

    {_seen, results} =
      Enum.reduce(events, {MapSet.new(), []}, fn ev, {seen, acc} ->
        with {:ok, %{"id" => ap_id} = note} <- fetch_inner_note(ev),
             true <- is_binary(ap_id),
             true <- poll_object?(note),
             false <- MapSet.member?(seen, ap_id) do
          {MapSet.put(seen, ap_id), [sync_poll(note, mode) | acc]}
        else
          _ -> {seen, acc}
        end
      end)

    summary = %{polls: tally(results), mode: mode}
    Logger.info("rebuild_from_archive run_polls done: #{inspect(summary)}")
    summary
  end

  # Create-or-refresh the local note's poll from this (newest) archived
  # Question. :dry_run reports which branch would run without writing.
  defp sync_poll(%{"id" => ap_id} = note, mode) do
    case Repo.get_by(Note, ap_id: ap_id) do
      %Note{id: nid} ->
        has_poll? = Polls.has_poll?(nid)

        cond do
          mode == :dry_run ->
            if has_poll?, do: :would_refresh, else: :would_attach

          has_poll? ->
            Polls.refresh_remote_poll_counts(nid, note)
            :refreshed

          true ->
            Polls.ingest_remote_poll(nid, note)
            :attached
        end

      nil ->
        :no_local_note
    end
  end

  # Recreate remote notes that are gone from `notes` but still in the
  # archive — *unless* the archive also holds a `Delete` for them (an
  # intentional removal we must not resurrect). Replays each surviving
  # `Create` through `Instructions.reingest_for_rebuild/1` (no mention
  # notification). :dry_run counts; :execute does the work.
  defp recreate_notes(mode) do
    present = present_ap_ids()
    deleted = deleted_ap_ids()

    create_events()
    |> Enum.map(fn ev ->
      case fetch_activity(ev) do
        {:ok, %{"object" => obj} = activity} ->
          case object_ap_id(obj) do
            ap_id when is_binary(ap_id) ->
              cond do
                MapSet.member?(present, ap_id) ->
                  :present

                MapSet.member?(deleted, ap_id) ->
                  :deleted

                mode == :dry_run ->
                  :would_recreate

                true ->
                  Instructions.reingest_for_rebuild(activity)
                  :recreated
              end

            _ ->
              :no_object_id
          end

        {:ok, _} ->
          :no_object_id

        {:error, reason} ->
          Logger.warning("  skip recreate #{ev.object_key}: #{inspect(reason)}")
          :error
      end
    end)
    |> tally()
  end

  defp create_events do
    from(e in InboundEvent, where: e.activity_type == "Create", order_by: e.received_at)
    |> Repo.all()
  end

  # ap_ids of remote notes we still have, to compare against the archive's
  # (remote) delete ids. Scoped by `domain` so local notes' own ap_ids
  # don't enter the set.
  defp present_ap_ids do
    from(n in Note, where: not is_nil(n.domain), select: n.ap_id)
    |> Repo.all()
    |> MapSet.new()
  end

  # ap_ids the archive says were deleted — download each `Delete` and read
  # its target. These must never be recreated.
  defp deleted_ap_ids do
    from(e in InboundEvent, where: e.activity_type == "Delete")
    |> Repo.all()
    |> Enum.flat_map(fn ev ->
      case fetch_activity(ev) do
        {:ok, %{"object" => obj}} -> List.wrap(object_ap_id(obj))
        _ -> []
      end
    end)
    |> MapSet.new()
  end

  defp object_ap_id(id) when is_binary(id), do: id
  defp object_ap_id(%{"id" => id}) when is_binary(id), do: id
  defp object_ap_id(_), do: nil

  # Replay archived `Announce` activities through the live boost handler so
  # past remote boosts surface as reblogs. `materialize_boost/1` is
  # idempotent and only acts on followed boosters, so a re-run is safe. It
  # writes, so :dry_run just counts the candidates.
  defp backfill_boosts(:dry_run) do
    %{archived: Repo.aggregate(announce_events_query(), :count, :id)}
  end

  defp backfill_boosts(:execute) do
    announce_events_query()
    |> Repo.all()
    |> Enum.map(fn ev ->
      case fetch_activity(ev) do
        {:ok, activity} ->
          Instructions.materialize_boost(activity)

        {:error, reason} ->
          Logger.warning("  skip boost #{ev.object_key}: #{inspect(reason)}")
          :error
      end
    end)
    |> tally()
  end

  defp announce_events_query do
    from(e in InboundEvent, where: e.activity_type == "Announce", order_by: e.received_at)
  end

  # Whole activity (not the inner object) — `materialize_boost/1` reads the
  # Announce's `actor` and `object`.
  defp fetch_activity(%InboundEvent{object_key: key}) do
    with {:ok, body} <- download(key) do
      JSON.decode(body)
    end
  end

  defp note_events do
    from(e in InboundEvent,
      where: e.activity_type in @note_activities,
      order_by: e.received_at
    )
    |> Repo.all()
  end

  # Download + decompress + decode one archived activity, returning its
  # embedded note object.
  defp fetch_inner_note(%InboundEvent{object_key: key}) do
    with {:ok, body} <- download(key),
         {:ok, json} <- JSON.decode(body),
         %{} = note <- inner_note(json) do
      {:ok, note}
    else
      nil -> {:error, :no_inline_note}
      {:error, _} = err -> err
    end
  end

  defp download(key) do
    bucket = Application.get_env(:sukhi_fedi, :s3, [])[:inbound_bucket] || "inbound"

    case bucket |> ExAws.S3.get_object(key) |> ExAws.request() do
      {:ok, %{body: compressed}} ->
        # :zstd.decompress/1 raises on bytes that aren't a zstd frame.
        try do
          {:ok, compressed |> :zstd.decompress() |> IO.iodata_to_binary()}
        rescue
          e -> {:error, {:zstd, e}}
        end

      {:error, reason} ->
        {:error, {:s3, reason}}
    end
  end

  # A Create/Update carries the note inline as `object`. A bare-id object
  # (just a URI) can't be reconstructed from, so it's skipped.
  defp inner_note(%{"object" => %{} = obj}), do: obj
  defp inner_note(_), do: nil

  @doc """
  Backfill the local note matching `note["id"]` from an archived note
  object. Sets `cw` / `created_at` only when the archive has a value that
  differs from what's stored. Exposed for testing.
  """
  @spec rebuild_note(map(), :dry_run | :execute) :: atom()
  def rebuild_note(%{"id" => ap_id} = note, mode) when is_binary(ap_id) do
    case Repo.get_by(Note, ap_id: ap_id) do
      %Note{} = existing ->
        changes = note_changes(note, existing)

        cond do
          changes == %{} -> :unchanged
          mode == :dry_run -> :would_update
          true -> existing |> Ecto.Changeset.change(changes) |> Repo.update!() && :updated
        end

      nil ->
        :no_local_note
    end
  end

  def rebuild_note(_, _), do: :no_object_id

  @doc """
  Backfill media for the local note matching `note["id"]` from the
  archived `attachment`. Idempotent: a note that already has media is left
  alone, so re-runs don't duplicate. Exposed for testing.
  """
  @spec backfill_media(map(), :dry_run | :execute) :: atom()
  def backfill_media(%{"id" => ap_id} = note, mode) when is_binary(ap_id) do
    atts = note["attachment"]

    case Repo.get_by(Note, ap_id: ap_id) do
      %Note{} = existing ->
        cond do
          not has_attachment?(atts) -> :no_media
          MediaIngest.has_media?(existing.id) -> :already
          mode == :dry_run -> :would_attach
          true -> MediaIngest.attach(existing.id, existing.account_id, atts) && :attached
        end

      nil ->
        :no_local_note
    end
  end

  def backfill_media(_, _), do: :no_object_id

  @doc """
  Backfill the poll for the local note matching `note["id"]` from an
  archived `Question` (`oneOf`/`anyOf`). The inbound Question was mirrored
  as a plain note before v0.4.7, so notes from before then carry no poll.
  Idempotent and create-only: a note that already owns a poll is left
  alone, so the first Question the caller feeds for a given note wins and
  later ones fall to `:already`. The caller picks the order — `run_polls`
  goes newest-first so the freshest tallies land. Exposed for testing.
  """
  @spec backfill_poll(map(), :dry_run | :execute) :: atom()
  def backfill_poll(%{"id" => ap_id} = note, mode) when is_binary(ap_id) do
    case Repo.get_by(Note, ap_id: ap_id) do
      %Note{} = existing ->
        cond do
          not poll_object?(note) ->
            :no_poll

          Polls.has_poll?(existing.id) ->
            :already

          mode == :dry_run ->
            :would_attach

          true ->
            Polls.ingest_remote_poll(existing.id, note)
            :attached
        end

      nil ->
        :no_local_note
    end
  end

  def backfill_poll(_, _), do: :no_object_id

  defp poll_object?(%{"oneOf" => list}) when is_list(list), do: list != []
  defp poll_object?(%{"anyOf" => list}) when is_list(list), do: list != []
  defp poll_object?(_), do: false

  defp has_attachment?(list) when is_list(list), do: list != []
  defp has_attachment?(%{}), do: true
  defp has_attachment?(_), do: false

  defp note_changes(note, %Note{} = existing) do
    %{}
    |> put_new_value(:cw, content_warning(note), existing.cw)
    |> put_new_value(:created_at, Published.at(note), existing.created_at)
    |> put_new_value(:emojis, Emojis.from_tag(note["tag"]), existing.emojis)
    # Only ever set sensitive (never clear it): an archived note without the
    # flag yields nil, which put_new_value skips.
    |> put_new_value(:sensitive, if(note["sensitive"] == true, do: true), existing.sensitive)
  end

  # Only a non-empty archive value that differs is a change — we never
  # clear a field the archive happens to omit.
  defp put_new_value(changes, _key, nil, _old), do: changes
  defp put_new_value(changes, _key, [], _old), do: changes
  defp put_new_value(changes, _key, value, value), do: changes
  defp put_new_value(changes, key, value, _old), do: Map.put(changes, key, value)

  defp content_warning(%{"summary" => s}) when is_binary(s) and s != "", do: s
  defp content_warning(_), do: nil

  defp tally(results) do
    Enum.reduce(results, %{}, fn r, acc -> Map.update(acc, r, 1, &(&1 + 1)) end)
  end
end
