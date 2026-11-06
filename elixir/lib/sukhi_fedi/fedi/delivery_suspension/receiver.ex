# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Fedi.DeliverySuspension.Receiver do
  @moduledoc """
  Takes in an inbound FEP-f799 control activity: `Create` / `Update` of a
  `DeliverySuspension` notice, and `Undo` of such a `Create`. The one place
  that decides whether a notice becomes (or stops being) a suspension; the
  checks are `SukhiShared.DeliverySuspension.*` (pure) and the memory is
  `Store`.

  The order is the spec draft's §6, cheap and local first:

    1. a small body (when the caller has the bytes) and a shallow document;
    2. genuine: the sender's HTTP signature host is the actor's host, and a
       notice that carries its own proof has it checked against its
       `attributedTo` (`Oip.verify_inbound/3` with `owner:`);
    3. the ids are the controller's own (`Notice.parse/2` for the notice and
       its announcement, here for the activity);
    4. the form (`Notice.parse/2`);
    5. control: the controller may speak for the target (`opts[:control]`,
       by default `Control`) — asked only for what *starts or extends* a
       suspension, never for a cancellation of a notice we already hold;
    6. fresh enough, and not behind the controller's cutoff;
    7. compared with what we hold (`plan/5`, pure): immutable members, the
       highest revision, the same revision with other content;
    8. written, then returned. The cache (stage 3) is filled from the store.

  A cancellation is final. `Undo`, `status: cancelled`, or an `Update` that
  carries it end the notice whatever its `revision`, and nothing brings it
  back, including a higher `revision` that arrives later. An `Undo` that
  names a `Create` we have not seen is held, by `(actor, create_id)`, and is
  applied before the `Create` it undoes takes effect.

  `handle/2` answers `:pass` for an activity that is not ours (the caller
  carries on with it), `{:ok, outcome}` or `{:error, reason}`. The reason is
  for telemetry (`[:sukhi_fedi, :delivery_suspension, :received]`) and logs,
  never for the sender.
  """

  alias SukhiFedi.Fedi.{Fetcher, Oip}
  alias SukhiFedi.Fedi.DeliverySuspension.{Control, Store}
  alias SukhiShared.DeliverySuspension.{Gate, Notice, Origin, Policy}

  @type outcome :: :accepted | :cancelled | :unchanged | :stale | :parked
  @type result :: :pass | {:ok, outcome()} | {:error, term()}

  @doc """
  Handle `activity`. Options:

    * `:signer_host` — the host whose HTTP signature carried it, or
      `:internal` for a trusted replay (required for anything to be taken)
    * `:raw_body` — the bytes it came in, for the size limit
    * `:now`, `:policy` — a `DateTime` and a `Policy` (defaults: now, default)
    * `:control` — `(Notice.t(), DateTime.t() -> :ok | {:error, term()})`
    * `:fetch_key` — as `Oip.verify_inbound/3`
  """
  @spec handle(term(), keyword()) :: result()
  def handle(activity, opts \\ [])

  def handle(%{} = activity, opts) do
    ctx = context(opts)

    result =
      case classify(activity) do
        :pass -> :pass
        {:publish, obj} -> publish(activity, obj, ctx)
        {:undo_inline, create, obj} -> undo_inline(activity, create, obj, ctx)
        {:undo_by_id, create_id} -> undo_by_id(activity, create_id, ctx)
      end

    announce(result, activity)
    result
  end

  def handle(_other, _opts), do: :pass

  # ── what the activity is ─────────────────────────────────────────────────

  defp classify(%{"object" => %{} = object} = activity) do
    cond do
      has_type?(activity, "Undo") ->
        classify_undo(object)

      has_type?(activity, "Create") or has_type?(activity, "Update") ->
        if Notice.notice?(object), do: {:publish, object}, else: :pass

      true ->
        :pass
    end
  end

  defp classify(%{"object" => id} = activity) when is_binary(id) do
    if has_type?(activity, "Undo"), do: {:undo_by_id, id}, else: :pass
  end

  defp classify(_), do: :pass

  defp classify_undo(%{} = create) do
    cond do
      not has_type?(create, "Create") ->
        :pass

      is_map(create["object"]) and Notice.notice?(create["object"]) ->
        {:undo_inline, create, create["object"]}

      is_binary(create["id"]) ->
        {:undo_by_id, create["id"]}

      true ->
        :pass
    end
  end

  defp has_type?(map, type), do: Notice.has_type?(map, type)

  # ── Create / Update ──────────────────────────────────────────────────────

  defp publish(activity, object, ctx) do
    with {:ok, actor} <- actor_of(activity),
         :ok <- small(ctx),
         :ok <- authentic(actor, ctx),
         :ok <- owned_id(activity["id"], actor, :bad_activity_id),
         :ok <- activity_fresh(activity, ctx),
         {:ok, proof_expires} <- notice_proof(object, ctx),
         {:ok, notice} <- parse(object, ctx),
         :ok <- same_controller(notice, actor),
         :ok <- notice_fresh(notice, ctx),
         :ok <- ahead_of_cutoff(notice) do
      notice = %{notice | proof_expires_at: proof_expires}
      decide(notice, activity["id"], object, ctx)
    end
  end

  # ── Undo ─────────────────────────────────────────────────────────────────

  # The Undo carries the Create and its notice: judge them as if they came
  # alone, then cancel. The notice's own `revision` is whatever the Create
  # had; a cancellation does not depend on it.
  defp undo_inline(undo, create, object, ctx) do
    with {:ok, actor} <- actor_of(undo),
         :ok <- small(ctx),
         :ok <- authentic(actor, ctx),
         :ok <- owned_id(undo["id"], actor, :bad_activity_id),
         :ok <- same_actor(actor_of(create), actor),
         :ok <- owned_id(create["id"], actor, :bad_activity_id),
         {:ok, notice} <- parse(object, ctx),
         :ok <- same_controller(notice, actor),
         :ok <- notice_fresh(notice, ctx),
         :ok <- ahead_of_cutoff(notice) do
      decide(%{notice | status: :cancelled}, create["id"], object, ctx)
    end
  end

  # The Undo names the Create by id. If we hold the notice it carried, it
  # ends; if not, it is held for the Create (and is not ours to answer:
  # the same shape undoes anything else a peer made).
  defp undo_by_id(undo, create_id, ctx) do
    with {:ok, actor} <- actor_of(undo),
         :ok <- authentic(actor, ctx) do
      case Store.get_notice_by_create(actor, create_id) do
        {:ok, held, _cid} ->
          with :ok <- small(ctx),
               :ok <- owned_id(undo["id"], actor, :bad_activity_id) do
            decide(%{held | status: :cancelled}, create_id, nil, ctx)
          end

        :none ->
          park(actor, create_id, ctx)
          :pass

        {:error, _} = error ->
          error
      end
    else
      # Not ours to judge: an unauthenticated Undo of an unknown Create is
      # an ordinary Undo, and the ordinary pipeline checks its signer.
      {:error, _} -> :pass
    end
  end

  defp park(actor, create_id, %{now: now, policy: policy}) do
    with true <- owned?(create_id, actor),
         false <- Store.pending?(actor, create_id, now) do
      _ = Store.put_pending(actor, create_id, now, policy)
    end

    :ok
  end

  # ── the checks ───────────────────────────────────────────────────────────

  defp context(opts) do
    %{
      signer_host: Keyword.get(opts, :signer_host),
      raw_body: Keyword.get(opts, :raw_body),
      now: Keyword.get_lazy(opts, :now, &DateTime.utc_now/0),
      policy: Keyword.get(opts, :policy, Policy.default()),
      control: Keyword.get(opts, :control, &Control.verify/2),
      fetch_key: Keyword.get(opts, :fetch_key)
    }
  end

  defp small(%{raw_body: body, policy: policy}) when is_binary(body) do
    if byte_size(body) <= policy.notice_max_bytes, do: :ok, else: {:error, :too_large}
  end

  defp small(_ctx), do: :ok

  defp actor_of(%{"actor" => actor}) when is_binary(actor), do: uri_ok(actor)
  defp actor_of(%{"actor" => %{"id" => actor}}) when is_binary(actor), do: uri_ok(actor)
  defp actor_of(_), do: {:error, :no_actor}

  defp uri_ok(uri) do
    case Origin.of_delivery_url(uri) do
      {:ok, _} -> {:ok, uri}
      :error -> {:error, :bad_actor}
    end
  end

  # The HTTP signature's host is the actor's host (the house standard,
  # `Instructions.trusted_inline_origin?/2`). Not a key-for-key match: the
  # inbox hands over the host, and a stronger binding would change that
  # contract for every activity.
  defp authentic(_actor, %{signer_host: :internal}), do: :ok

  defp authentic(actor, %{signer_host: host}) when is_binary(host) do
    case URI.parse(actor) do
      %URI{host: h} when is_binary(h) ->
        if String.downcase(h) == String.downcase(host), do: :ok, else: {:error, :signer_mismatch}

      _ ->
        {:error, :signer_mismatch}
    end
  end

  defp authentic(_actor, _ctx), do: {:error, :unauthenticated}

  defp owned_id(id, actor, reason) when is_binary(id) do
    if owned?(id, actor), do: :ok, else: {:error, reason}
  end

  defp owned_id(_id, _actor, reason), do: {:error, reason}

  defp owned?(url, actor) when is_binary(url) do
    match?({:ok, _}, Origin.of_delivery_url(url)) and
      Origin.of_delivery_url(url) == Origin.of_delivery_url(actor)
  end

  defp owned?(_url, _actor), do: false

  defp activity_fresh(%{"published" => value}, ctx) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, time, _} -> fresh(time, ctx)
      _ -> {:error, :bad_activity_time}
    end
  end

  defp activity_fresh(_activity, _ctx), do: :ok

  defp notice_fresh(%Notice{published: published}, ctx), do: fresh(published, ctx)

  defp fresh(time, %{now: now, policy: policy}) do
    cond do
      DateTime.compare(time, DateTime.add(now, policy.future_skew, :second)) == :gt ->
        {:error, :from_the_future}

      DateTime.compare(time, DateTime.add(now, -policy.notice_max_age, :second)) == :lt ->
        {:error, :too_old}

      true ->
        :ok
    end
  end

  defp ahead_of_cutoff(%Notice{controller: controller, published: published}) do
    case Store.cutoff(controller) do
      %DateTime{} = cutoff ->
        if DateTime.compare(published, cutoff) == :lt, do: {:error, :before_cutoff}, else: :ok

      nil ->
        :ok
    end
  end

  defp parse(object, %{policy: policy}) do
    case Notice.parse(object, policy) do
      {:ok, notice} -> {:ok, notice}
      {:error, reason} -> {:error, {:form, reason}}
    end
  end

  defp same_actor({:ok, actor}, actor), do: :ok
  defp same_actor(_other, _actor), do: {:error, :undo_not_by_creator}

  defp same_controller(%Notice{controller: actor}, actor), do: :ok
  defp same_controller(_notice, _actor), do: {:error, :controller_is_not_actor}

  # A notice that carries its own proof has it checked against its owner,
  # `attributedTo`. Without `owner:` a document with no `actor` is not
  # compared at all, which would let any key sign any notice.
  defp notice_proof(%{"proof" => _} = object, ctx) do
    fetch = ctx.fetch_key || (&Fetcher.fetch_cached/2)

    case Oip.verify_inbound(object, fetch, owner: "attributedTo") do
      :ok -> {:ok, proof_expiry(object)}
      :no_proof -> {:ok, nil}
      :no_checkable_proof -> {:ok, nil}
      {:error, _} -> {:error, :proof_failed}
    end
  end

  defp notice_proof(_object, _ctx), do: {:ok, nil}

  # The earliest `expires` among the proofs: the notice does not outlive the
  # signature it was believed on.
  defp proof_expiry(%{"proof" => proof}) do
    proof
    |> List.wrap()
    |> Enum.flat_map(fn
      %{"expires" => value} when is_binary(value) ->
        case DateTime.from_iso8601(value) do
          {:ok, time, _} -> [time]
          _ -> []
        end

      _ ->
        []
    end)
    |> case do
      [] -> nil
      times -> Enum.min(times, DateTime)
    end
  end

  # ── compare, check control, write ────────────────────────────────────────

  defp decide(notice, create_id, document, ctx) do
    with {:ok, state} <- read_state(notice, create_id, ctx) do
      case plan(state, notice, ctx) do
        {:noop, outcome} ->
          {:ok, outcome}

        {:reject, reason} ->
          {:error, reason}

        {:write, _record, needs_control?} ->
          persist(notice, create_id, document, ctx, needs_control?)
      end
    end
  end

  # Control first (it may fetch, so it never runs under the write lock), then
  # the same plan again under the lock: if something moved in between, a
  # write that now needs control we did not ask for is refused, not guessed.
  defp persist(notice, create_id, document, ctx, needs_control?) do
    with :ok <- if(needs_control?, do: ctx.control.(notice, ctx.now), else: :ok) do
      Store.exclusive(fn ->
        with {:ok, state} <- read_state(notice, create_id, ctx) do
          case plan(state, notice, ctx) do
            {:noop, outcome} ->
              {:ok, outcome}

            {:reject, reason} ->
              {:error, reason}

            {:write, _record, true} when not needs_control? ->
              {:error, :changed_concurrently}

            {:write, record, _} ->
              write(state, record, create_id, document, ctx)
          end
        end
      end)
    end
  end

  defp read_state(notice, create_id, %{now: now}) do
    held =
      case Store.get_notice(notice.id) do
        {:ok, known, known_create_id} -> {known, known_create_id}
        :none -> nil
        {:error, _} = error -> error
      end

    case held do
      {:error, _} = error ->
        error

      held ->
        {:ok,
         %{
           held: held,
           parked?:
             held == nil and is_binary(create_id) and
               Store.pending?(notice.controller, create_id, now)
         }}
    end
  end

  defp write(state, record, create_id, document, ctx) do
    kept_create_id =
      case state.held do
        {_known, known_create_id} when is_binary(known_create_id) -> known_create_id
        _ -> create_id
      end

    with :ok <- room_for(state, record, ctx),
         :ok <-
           Store.put_notice(record,
             create_id: kept_create_id,
             snapshot: document && JSON.encode!(document)
           ),
         :ok <-
           if(state.parked?, do: Store.delete_pending(record.controller, create_id), else: :ok) do
      {:ok, if(record.status == :cancelled, do: :cancelled, else: :accepted)}
    end
  end

  defp room_for(%{held: nil}, record, %{policy: policy}) do
    if Store.count_notices(record.controller) < policy.max_notices_per_controller,
      do: :ok,
      else: {:error, :too_many_notices}
  end

  defp room_for(_state, _record, _ctx), do: :ok

  @doc false
  # The decision, pure. `held` is `{known, create_id}` or nil; `parked?` says
  # an Undo for this Create is waiting. Returns `{:write, record, needs_control?}`,
  # `{:noop, outcome}` or `{:reject, reason}`.
  @spec plan(map(), Notice.t(), map()) ::
          {:write, Notice.t(), boolean()} | {:noop, outcome()} | {:reject, term()}
  def plan(%{held: nil, parked?: parked?}, %Notice{} = notice, %{now: now}) do
    record =
      if parked? or notice.status == :cancelled,
        do: cancel(notice, now),
        else: settle(notice, nil, now)

    {:write, record, true}
  end

  def plan(%{held: {%Notice{} = known, _create_id}}, %Notice{} = notice, ctx) do
    cond do
      not Notice.same_immutable?(known, notice) ->
        {:reject, :immutable_changed}

      known.status == :cancelled and notice.status == :cancelled ->
        {:noop, :unchanged}

      known.status == :cancelled ->
        {:reject, :cancelled_is_final}

      notice.status == :cancelled ->
        # Ends something we hold: no re-check needed, it can only shorten.
        {:write, cancel(%{known | revision: max(known.revision, notice.revision)}, ctx.now),
         false}

      notice.revision < known.revision ->
        {:noop, :stale}

      notice.revision == known.revision ->
        if same_content?(known, notice),
          do: {:noop, :unchanged},
          else: {:reject, :same_revision_different_content}

      true ->
        record = settle(notice, known, ctx.now)
        {:write, record, extends?(known, record, ctx.policy)}
    end
  end

  # An accepted active notice: when it starts is fixed the first time (no
  # `startTime` means "when we first took it"), and kept by later revisions.
  defp settle(notice, known, now) do
    %{
      notice
      | effective_start: notice.start_time || (known && known.effective_start) || now,
        accepted_at: (known && known.accepted_at) || now,
        cancelled_at: nil
    }
  end

  defp cancel(%Notice{} = notice, now) do
    %{
      notice
      | status: :cancelled,
        cancelled_at: notice.cancelled_at || now,
        effective_start: notice.effective_start || now,
        accepted_at: notice.accepted_at || now
    }
  end

  defp same_content?(a, b) do
    a.status == b.status and a.summary == b.summary and a.url == b.url and
      same_time?(a.start_time, b.start_time) and same_time?(a.end_time, b.end_time)
  end

  defp same_time?(nil, nil), do: true
  defp same_time?(%DateTime{} = a, %DateTime{} = b), do: DateTime.compare(a, b) == :eq
  defp same_time?(_, _), do: false

  # Does the new revision keep the suspension going longer, or start it
  # sooner, than the one we hold? Then it is "extending" and waits for a
  # fresh control check; one that only shortens does not.
  defp extends?(known, record, policy) do
    later_end? =
      DateTime.compare(Gate.effective_end(record, policy), Gate.effective_end(known, policy)) ==
        :gt

    earlier_start? = DateTime.compare(record.effective_start, known.effective_start) == :lt
    later_end? or earlier_start?
  end

  # ── telemetry ────────────────────────────────────────────────────────────

  defp announce(:pass, _activity), do: :ok

  defp announce(result, activity) do
    {status, detail} =
      case result do
        {:ok, outcome} -> {:ok, outcome}
        {:error, reason} -> {:rejected, reason}
      end

    :telemetry.execute(
      [:sukhi_fedi, :delivery_suspension, :received],
      %{count: 1},
      %{status: status, detail: detail, type: activity["type"]}
    )

    if status == :rejected do
      require Logger
      Logger.info("delivery_suspension: rejected #{inspect(detail)} (#{inspect(activity["id"])})")
    end
  end
end
