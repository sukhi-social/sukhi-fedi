# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Fedi.DeliverySuspension.Store do
  @moduledoc """
  What FEP-f799 remembers, in PostgreSQL (`SukhiFedi.AccountRepo`; the tables
  are `suspension_notices`, `suspension_pending`, `suspension_evidence` and
  `suspension_cutoffs`, in `priv/account_repo/migrations`; and
  `suspension_ignores`, below). Four kinds of row, no references:

    * **notices** — one per notice `id`. A cancelled row is kept as the
      mark that ends it: a later, higher `revision` does not bring it back.
    * **pending cancellations** — an `Undo` that arrived before the `Create`
      it undoes, held by `(actor, create_id)` until the `Create` shows up or
      the notice-age limit passes. Capped per actor and in all.
    * **control evidence** — the last time a controller's right to speak for
      a target was freshly confirmed (written by the control check, stage 4).
    * **controller cutoffs** — "nothing published before this is accepted
      from this controller". Forgetting a notice (`sweep/2`) advances it by
      as much, so loosening the age limit later cannot revive a cancelled
      notice we no longer remember.

  A fifth table, `suspension_ignores`, holds the notice ids an admin chose to
  ignore on this server: our own choice, kept beside the notices and never
  written into them.

  Reads never lock. A caller that reads and then writes does both inside
  `exclusive/1` (one holder at a time on this node), and never nests it;
  nothing here takes the lock itself. A single write is its own whole step.

  Times in rows are microseconds since the epoch; a `Notice`'s `DateTime`s
  travel as ISO 8601 inside the `record` JSON, which is the authority for
  reading a notice back (the other `suspension_notices` columns are for
  finding rows).

  A database that cannot be reached answers `{:error, _}` where the function
  can say so, and what it would have found if there were nothing (`0`, `false`,
  `nil`, no rows) where it cannot.
  """

  import Ecto.Query, only: [from: 2]

  alias SukhiFedi.AccountRepo
  alias SukhiShared.DeliverySuspension.{Notice, Policy}

  @doc "Run `fun` as the only writer on this node. Not re-entrant."
  @spec exclusive((-> result)) :: result when result: term()
  def exclusive(fun) do
    :global.trans({{__MODULE__, :write}, self()}, fun, [node()], :infinity)
  end

  # ── notices ──────────────────────────────────────────────────────────────

  @doc """
  The stored notice with this `id`, with the id of the `Create` that carried
  it (`nil` if it arrived as an `Update` first).
  """
  @spec get_notice(String.t()) :: {:ok, Notice.t(), String.t() | nil} | :none | {:error, term()}
  def get_notice(id) when is_binary(id) do
    read_one(from(n in "suspension_notices", where: n.id == ^id, select: {n.record, n.create_id}))
  end

  @doc "The notice that `actor`'s `Create` `create_id` carried, if we have it."
  @spec get_notice_by_create(String.t(), String.t()) ::
          {:ok, Notice.t(), String.t() | nil} | :none | {:error, term()}
  def get_notice_by_create(actor, create_id) when is_binary(actor) and is_binary(create_id) do
    read_one(
      from(n in "suspension_notices",
        where: n.controller == ^actor and n.create_id == ^create_id,
        select: {n.record, n.create_id},
        limit: 1
      )
    )
  end

  @doc "Every stored notice: what the cache is rebuilt from after a restart."
  @spec all_notices() :: {:ok, [Notice.t()]} | {:error, term()}
  def all_notices do
    case guard(fn -> AccountRepo.all(from(n in "suspension_notices", select: n.record)) end) do
      {:error, _} = error -> error
      records -> {:ok, Enum.map(records, &decode/1)}
    end
  end

  @doc "How many notices this controller has with us (cancelled ones count: they are marks)."
  @spec count_notices(String.t()) :: non_neg_integer()
  def count_notices(controller) when is_binary(controller) do
    count(from(n in "suspension_notices", where: n.controller == ^controller, select: count()))
  end

  @doc """
  Write `notice` (insert or replace by `id`). Options: `:create_id`, and
  `:snapshot`, the document as received. A write that gives neither leaves
  what an earlier one stored.
  """
  @spec put_notice(Notice.t(), keyword()) :: :ok | {:error, term()}
  def put_notice(%Notice{} = n, opts \\ []) do
    row = %{
      id: n.id,
      controller: n.controller,
      target_kind: Atom.to_string(n.target_kind),
      target: n.target,
      status: Atom.to_string(n.status),
      revision: n.revision,
      published: micros(n.published),
      record: encode(n),
      create_id: opts[:create_id],
      snapshot: opts[:snapshot]
    }

    replace =
      [:controller, :target_kind, :target, :status, :revision, :published, :record] ++
        Enum.filter([:create_id, :snapshot], &Map.get(row, &1))

    write(fn ->
      AccountRepo.insert_all("suspension_notices", [row],
        conflict_target: :id,
        on_conflict: {:replace, replace}
      )
    end)
  end

  # ── ignored by an admin ──────────────────────────────────────────────────

  @doc "Ignore the notice `id` here (its record is left as the peer wrote it). Idempotent."
  @spec ignore(String.t(), DateTime.t()) :: :ok | {:error, term()}
  def ignore(id, %DateTime{} = at) when is_binary(id) do
    write(fn ->
      AccountRepo.insert_all("suspension_ignores", [%{notice_id: id, ignored_at: micros(at)}],
        conflict_target: :notice_id,
        on_conflict: :nothing
      )
    end)
  end

  @doc "Stop ignoring the notice `id`."
  @spec unignore(String.t()) :: :ok | {:error, term()}
  def unignore(id) when is_binary(id) do
    write(fn -> AccountRepo.delete_all(from(i in "suspension_ignores", where: i.notice_id == ^id)) end)
  end

  @doc "The ids of the notices ignored here, with when."
  @spec ignored() :: {:ok, %{String.t() => DateTime.t()}} | {:error, term()}
  def ignored do
    case guard(fn ->
           AccountRepo.all(from(i in "suspension_ignores", select: {i.notice_id, i.ignored_at}))
         end) do
      {:error, _} = error -> error
      rows -> {:ok, Map.new(rows, fn {id, at} -> {id, from_micros(at)} end)}
    end
  end

  # ── pending cancellations ────────────────────────────────────────────────

  @doc """
  Hold an `Undo` whose `Create` has not arrived. `{:error, :full}` when
  the actor (or the table) is at its cap: the caller drops it, which only
  costs us a cancellation we would have had to fetch to believe anyway.
  """
  @spec put_pending(String.t(), String.t(), DateTime.t(), Policy.t()) ::
          :ok | {:error, :full | term()}
  def put_pending(actor, create_id, %DateTime{} = now, %Policy{} = policy) do
    cond do
      count(from(p in "suspension_pending", where: p.actor == ^actor, select: count())) >=
          policy.max_pending_per_actor ->
        {:error, :full}

      count(from(p in "suspension_pending", select: count())) >= policy.max_pending_total ->
        {:error, :full}

      true ->
        row = %{
          actor: actor,
          create_id: create_id,
          received_at: micros(now),
          expires_at: micros(DateTime.add(now, policy.notice_max_age, :second))
        }

        write(fn ->
          AccountRepo.insert_all("suspension_pending", [row],
            conflict_target: [:actor, :create_id],
            on_conflict: {:replace, [:received_at, :expires_at]}
          )
        end)
    end
  end

  @doc "Is an `Undo` held for this `(actor, create_id)` that has not expired?"
  @spec pending?(String.t(), String.t(), DateTime.t()) :: boolean()
  def pending?(actor, create_id, %DateTime{} = now) do
    at = micros(now)

    count(
      from(p in "suspension_pending",
        where: p.actor == ^actor and p.create_id == ^create_id and p.expires_at > ^at,
        select: count()
      )
    ) > 0
  end

  @doc "Drop the held `Undo` for `(actor, create_id)`, once it has been applied."
  @spec delete_pending(String.t(), String.t()) :: :ok | {:error, term()}
  def delete_pending(actor, create_id) do
    write(fn ->
      AccountRepo.delete_all(
        from(p in "suspension_pending", where: p.actor == ^actor and p.create_id == ^create_id)
      )
    end)
  end

  # ── control evidence (stage 4 writes it; the row is here so the shape is one) ──

  @type evidence :: %{
          verified_at: DateTime.t() | nil,
          attempted_at: DateTime.t() | nil,
          failure: atom() | nil
        }

  @spec get_evidence(atom(), String.t(), String.t()) :: {:ok, evidence()} | :none
  def get_evidence(kind, target, controller) when is_atom(kind) do
    kind = Atom.to_string(kind)

    query =
      from(e in "suspension_evidence",
        where: e.kind == ^kind and e.target == ^target and e.controller == ^controller,
        select: {e.verified_at, e.attempted_at, e.failure}
      )

    case guard(fn -> AccountRepo.one(query) end) do
      {verified_at, attempted_at, failure} ->
        {:ok,
         %{
           verified_at: from_micros(verified_at),
           attempted_at: from_micros(attempted_at),
           failure: failure(failure)
         }}

      _ ->
        :none
    end
  end

  @doc """
  Every control-evidence row, for a screen that shows many notices at once
  (one read, not one per notice): `%{{kind, target, controller} => evidence}`.
  """
  @spec all_evidence() :: %{{atom(), String.t(), String.t()} => evidence()}
  def all_evidence do
    query =
      from(e in "suspension_evidence",
        select: {e.kind, e.target, e.controller, e.verified_at, e.attempted_at, e.failure}
      )

    for {kind, target, controller, verified_at, attempted_at, failure} <- rows(query), into: %{} do
      {{String.to_existing_atom(kind), target, controller},
       %{
         verified_at: from_micros(verified_at),
         attempted_at: from_micros(attempted_at),
         failure: failure(failure)
       }}
    end
  end

  @doc "Record an attempt: `verified_at` only moves when `attrs` has one."
  @spec put_evidence(atom(), String.t(), String.t(), map()) :: :ok | {:error, term()}
  def put_evidence(kind, target, controller, attrs) when is_atom(kind) do
    row = %{
      kind: Atom.to_string(kind),
      target: target,
      controller: controller,
      verified_at: micros(attrs[:verified_at]),
      attempted_at: micros(attrs[:attempted_at]),
      failure: attrs[:failure] && Atom.to_string(attrs[:failure])
    }

    # A second attempt rewrites only what it has to say.
    given = Enum.filter([:verified_at, :attempted_at, :failure], &Map.get(row, &1))

    write(fn ->
      AccountRepo.insert_all("suspension_evidence", [row],
        conflict_target: [:kind, :target, :controller],
        on_conflict: if(given == [], do: :nothing, else: {:replace, given})
      )
    end)
  end

  # ── cutoffs ──────────────────────────────────────────────────────────────

  @doc "The controller's cutoff: notices published before it are not accepted. `nil` = none."
  @spec cutoff(String.t()) :: DateTime.t() | nil
  def cutoff(controller) when is_binary(controller) do
    query = from(c in "suspension_cutoffs", where: c.controller == ^controller, select: c.not_before)

    case guard(fn -> AccountRepo.one(query) end) do
      n when is_integer(n) -> from_micros(n)
      _ -> nil
    end
  end

  @doc "Move the controller's cutoff forward to `at` (never back)."
  @spec advance_cutoff(String.t(), DateTime.t()) :: :ok | {:error, term()}
  def advance_cutoff(controller, %DateTime{} = at) do
    row = %{controller: controller, not_before: micros(at)}

    forward =
      from(c in "suspension_cutoffs",
        update: [set: [not_before: fragment("GREATEST(?, EXCLUDED.not_before)", c.not_before)]]
      )

    write(fn ->
      AccountRepo.insert_all("suspension_cutoffs", [row],
        conflict_target: :controller,
        on_conflict: forward
      )
    end)
  end

  # ── forgetting ───────────────────────────────────────────────────────────

  @doc """
  Forget what can no longer be accepted anyway: notices published longer ago
  than the age limit, and held `Undo`s past their expiry. Each forgotten
  notice advances its controller's cutoff past its `published`, so the
  cancellation is remembered by the line even when the row is gone.
  Returns `%{notices: n, pending: m}`.
  """
  @spec sweep(DateTime.t(), Policy.t()) :: %{
          notices: non_neg_integer(),
          pending: non_neg_integer()
        }
  def sweep(%DateTime{} = now, %Policy{} = policy) do
    horizon = micros(DateTime.add(now, -policy.notice_max_age, :second))

    old =
      rows(
        from(n in "suspension_notices",
          where: n.published < ^horizon,
          select: {n.id, n.controller, n.published}
        )
      )

    # Cutoffs first: if we stop between the two steps, the line is ahead of
    # the rows, which is the safe side.
    old
    |> Enum.group_by(fn {_id, c, _p} -> c end, fn {_id, _c, p} -> p end)
    |> Enum.each(fn {controller, published} ->
      # The first instant still acceptable: the forgotten notice's own
      # `published` must be refused too.
      _ = advance_cutoff(controller, from_micros(Enum.max(published) + 1))
    end)

    ids = for {id, _c, _p} <- old, do: id
    _ = write(fn -> AccountRepo.delete_all(from(n in "suspension_notices", where: n.id in ^ids)) end)
    # An ignore with no notice behind it has nothing left to ignore.
    _ = write(fn -> AccountRepo.delete_all(from(i in "suspension_ignores", where: i.notice_id in ^ids)) end)

    at = micros(now)
    expired = from(p in "suspension_pending", where: p.expires_at <= ^at)

    pending =
      case guard(fn -> AccountRepo.delete_all(expired) end) do
        {n, _} when is_integer(n) -> n
        _ -> 0
      end

    %{notices: length(old), pending: pending}
  end

  # ── plumbing ─────────────────────────────────────────────────────────────

  # A connection that is not there is an answer (`{:error, _}`), not a crash:
  # a caller that cannot reach the store has to say so, or carry on without it.
  defp guard(fun) do
    fun.()
  rescue
    error in [DBConnection.ConnectionError, Postgrex.Error] -> {:error, error}
  end

  defp write(fun) do
    guard(fn ->
      _ = fun.()
      :ok
    end)
  end

  defp rows(query) do
    case guard(fn -> AccountRepo.all(query) end) do
      rows when is_list(rows) -> rows
      _ -> []
    end
  end

  defp count(query) do
    case guard(fn -> AccountRepo.one(query) end) do
      n when is_integer(n) -> n
      _ -> 0
    end
  end

  defp read_one(query) do
    case guard(fn -> AccountRepo.one(query) end) do
      nil -> :none
      {:error, _} = error -> error
      {record, create_id} -> {:ok, decode(record), create_id}
    end
  end

  defp micros(nil), do: nil
  defp micros(%DateTime{} = dt), do: DateTime.to_unix(dt, :microsecond)

  defp from_micros(n) when is_integer(n) and n > 0, do: DateTime.from_unix!(n, :microsecond)
  defp from_micros(_), do: nil

  defp failure(nil), do: nil
  defp failure("none"), do: nil
  defp failure(name) when is_binary(name), do: String.to_existing_atom(name)

  # The record is the whole notice, times as ISO 8601 text.
  @times ~w(published start_time end_time effective_start proof_expires_at accepted_at cancelled_at)a

  defp encode(%Notice{} = n) do
    n
    |> Map.from_struct()
    |> Map.new(fn
      {k, %DateTime{} = v} when k in @times -> {k, DateTime.to_iso8601(v)}
      {k, v} when k in [:target_kind, :status] -> {k, Atom.to_string(v)}
      pair -> pair
    end)
    |> JSON.encode!()
  end

  defp decode(json) do
    map = JSON.decode!(json)

    fields =
      for {key, value} <- map, into: %{} do
        k = String.to_existing_atom(key)

        v =
          cond do
            k in @times and is_binary(value) ->
              {:ok, dt, _} = DateTime.from_iso8601(value)
              dt

            k in [:target_kind, :status] ->
              String.to_existing_atom(value)

            true ->
              value
          end

        {k, v}
      end

    struct!(Notice, fields)
  end
end
