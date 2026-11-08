# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Fedi.DeliverySuspension.Recheck do
  @moduledoc """
  A resting notice relies on its controller still speaking for the target
  (`Control`). This looks again, for the notices that are in effect now, so a
  link that has been taken away stops the rest (spec draft §7).

  What each answer does:

    * `:ok` — the evidence is renewed. Nothing else changes; in particular the
      notice's end does not move.
    * `{:unlinked, _}` — we read the documents and the link is gone. The
      notice is **withdrawn**: it stays in the store (its revision and
      immutable members are still remembered) but is no longer accepted, so
      the delivery worker lets everything through. This is not a
      cancellation: the same revision can be taken again, through the ordinary
      check, if the link comes back.
    * `{:unreachable, _}` — we could not read them. Neither a cancellation nor
      a reason to extend: the notice keeps its own end, and the attempt is
      only recorded.

  A notice is looked at again only when the last attempt is older than
  `:every` seconds (default one hour), so the hourly pass is not a fetch per
  notice per run, and a flapping host is not hammered.

  Options: `:every`, `:policy`, `:control` (default `Control.verify/3`), and
  whatever `Control` takes (`:http`).
  """

  require Logger

  alias SukhiFedi.Fedi.DeliverySuspension.{Control, Store}
  alias SukhiShared.DeliverySuspension.{Cache, Gate, Notice, Policy}

  @every 3_000

  @spec run(DateTime.t(), keyword()) :: %{
          checked: non_neg_integer(),
          withdrawn: non_neg_integer(),
          unreachable: non_neg_integer()
        }
  def run(%DateTime{} = now, opts \\ []) do
    policy = Keyword.get(opts, :policy, Policy.default())
    every = Keyword.get(opts, :every, @every)
    control = Keyword.get(opts, :control, &Control.verify/3)

    case Store.all_notices() do
      {:ok, notices} ->
        notices
        |> Enum.filter(&(current?(&1, now, policy) and due?(&1, now, every)))
        |> Enum.reduce(%{checked: 0, withdrawn: 0, unreachable: 0}, fn notice, acc ->
          step(control.(notice, now, opts), notice, acc)
        end)

      {:error, reason} ->
        Logger.warning(
          "delivery_suspension: recheck could not read the store: #{inspect(reason)}"
        )

        %{checked: 0, withdrawn: 0, unreachable: 0}
    end
  end

  defp step(:ok, _notice, acc), do: announce(:ok, %{acc | checked: acc.checked + 1})

  defp step({:error, {:unlinked, why}}, notice, acc) do
    withdraw(notice)
    announce({:withdrawn, why}, %{acc | checked: acc.checked + 1, withdrawn: acc.withdrawn + 1})
  end

  defp step({:error, {:unreachable, why}}, _notice, acc) do
    announce(
      {:unreachable, why},
      %{acc | checked: acc.checked + 1, unreachable: acc.unreachable + 1}
    )
  end

  # In effect now: accepted, active, inside its window.
  defp current?(
         %Notice{status: :active, accepted_at: %DateTime{}, effective_start: %DateTime{}} = n,
         now,
         policy
       ) do
    DateTime.compare(n.effective_start, now) != :gt and
      DateTime.compare(now, Gate.effective_end(n, policy)) == :lt
  end

  defp current?(_notice, _now, _policy), do: false

  defp due?(notice, now, every) do
    last =
      notice
      |> Control.kinds()
      |> Enum.flat_map(fn kind ->
        case Store.get_evidence(kind, notice.target, notice.controller) do
          {:ok, %{attempted_at: %DateTime{} = at}} -> [at]
          _ -> []
        end
      end)
      |> Enum.max(DateTime, fn -> nil end)

    last == nil or DateTime.diff(now, last, :second) >= every
  end

  # Read it again under the lock: it may have been cancelled or replaced
  # while we were out fetching, and then there is nothing to withdraw.
  defp withdraw(%Notice{id: id, revision: revision}) do
    Store.exclusive(fn ->
      case Store.get_notice(id) do
        {:ok, %Notice{revision: ^revision, status: :active, accepted_at: %DateTime{}} = held,
         create_id} ->
          withdrawn = %{held | accepted_at: nil}

          with :ok <- Store.put_notice(withdrawn, create_id: create_id) do
            Cache.put(withdrawn)
          end

        _ ->
          :ok
      end
    end)
  end

  defp announce(result, acc) do
    {status, detail} =
      case result do
        :ok -> {:ok, nil}
        {status, detail} -> {status, detail}
      end

    :telemetry.execute([:sukhi_fedi, :delivery_suspension, :recheck], %{count: 1}, %{
      status: status,
      detail: detail
    })

    acc
  end
end
