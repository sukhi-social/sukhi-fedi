# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiShared.DeliverySuspension.Gate do
  @moduledoc """
  "Is delivery to this URL suspended right now?" — the one function that
  answers (FEP-f799 spec draft §5). Pure: the time and the notices are
  arguments, so it is tested by moving `now`, and the delivery worker and the
  admin screen cannot disagree about it.

  The promises it keeps:

    * **An end always comes.** A suspension's effective end is the earliest of
      `endTime`, the proof's expiry (if we rely on it), `published` + the
      notice age limit, and `effective_start` + the longest suspension.
      Nothing here lets a re-check, a re-delivery or a cache hit move it later.
    * **When in doubt, deliver.** A URL we cannot read an origin from is not
      suspended. A notice nobody has accepted is not in effect.
    * **Cancelled stays cancelled.** A cancelled notice is never in effect.
  """

  alias SukhiShared.DeliverySuspension.{Notice, Origin, Policy}

  @doc """
  True when any one notice is in effect for `delivery_url` at `now`. One
  notice ending does not end the others.
  """
  @spec suspended?(String.t(), DateTime.t(), [Notice.t()], Policy.t()) :: boolean()
  def suspended?(delivery_url, %DateTime{} = now, notices, %Policy{} = policy)
      when is_binary(delivery_url) and is_list(notices) do
    case Origin.of_delivery_url(delivery_url) do
      {:ok, origin} -> Enum.any?(notices, &in_effect?(&1, delivery_url, origin, now, policy))
      :error -> false
    end
  end

  def suspended?(_delivery_url, _now, _notices, _policy), do: false

  @doc """
  When deliveries to `delivery_url` may resume: the latest effective end among
  the notices now in effect for it, or `nil` if it is not suspended. This is
  where to schedule the next look; it is checked again then, because a notice
  may have been cancelled in the meantime.
  """
  @spec resume_at(String.t(), DateTime.t(), [Notice.t()], Policy.t()) :: DateTime.t() | nil
  def resume_at(delivery_url, %DateTime{} = now, notices, %Policy{} = policy)
      when is_binary(delivery_url) and is_list(notices) do
    case Origin.of_delivery_url(delivery_url) do
      {:ok, origin} ->
        notices
        |> Enum.filter(&in_effect?(&1, delivery_url, origin, now, policy))
        |> Enum.map(&effective_end(&1, policy))
        |> Enum.max(DateTime, fn -> nil end)

      :error ->
        nil
    end
  end

  @doc false
  @spec in_effect?(Notice.t(), String.t(), String.t(), DateTime.t(), Policy.t()) :: boolean()
  def in_effect?(%Notice{} = notice, delivery_url, origin, now, policy) do
    accepted?(notice) and in_scope?(notice, delivery_url, origin) and
      within_window?(notice, now, policy)
  end

  @doc """
  The earliest of the four bounds (spec draft §5). A notice that has no
  `effective_start` yet has not been accepted and has no end to speak of; it
  is never asked (`in_effect?/5` checks acceptance first).
  """
  @spec effective_end(Notice.t(), Policy.t()) :: DateTime.t()
  def effective_end(%Notice{effective_start: %DateTime{} = start} = notice, %Policy{} = policy) do
    [
      notice.end_time,
      notice.proof_expires_at,
      DateTime.add(notice.published, policy.notice_max_age, :second),
      DateTime.add(start, policy.max_suspension, :second)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.min(DateTime)
  end

  @doc """
  Deliveries that suspension must not hold back: the notice itself and its
  cancellation — `Create`/`Update` of a `DeliverySuspension`, and an `Undo`
  of such a `Create`. Judged by what the activity **contains**, not by its
  type alone: an ordinary Create, Update or Undo is held like anything else.

  An `Undo` whose `object` is only an id cannot be judged here; the caller
  that knows the `Create` passes it inline (our own publisher does).
  """
  @spec exempt?(term()) :: boolean()
  def exempt?(%{} = activity) do
    case {Map.get(activity, "type"), Map.get(activity, "object")} do
      {type, %{} = object} when type in ["Create", "Update"] -> Notice.notice?(object)
      {"Undo", %{} = create} -> undoes_notice_create?(create)
      _ -> false
    end
  end

  def exempt?(_), do: false

  defp undoes_notice_create?(%{} = create) do
    Notice.has_type?(create, "Create") and Notice.notice?(Map.get(create, "object"))
  end

  # ── pieces ───────────────────────────────────────────────────────────────

  defp accepted?(%Notice{accepted_at: nil}), do: false
  defp accepted?(%Notice{effective_start: nil}), do: false
  defp accepted?(%Notice{status: :active, cancelled_at: nil}), do: true
  defp accepted?(%Notice{}), do: false

  # `targetInbox` is the exact delivery URL. `targetOrigin` is the origin
  # computed from the URL we are about to POST to — not from the id of the
  # actor it was addressed to — and a subdomain or another port is another origin.
  defp in_scope?(%Notice{target_kind: :inbox, target: target}, delivery_url, _origin),
    do: target == delivery_url

  defp in_scope?(%Notice{target_kind: :origin, target: target}, _delivery_url, origin),
    do: target == origin

  # effective_start <= now < effective_end
  defp within_window?(%Notice{effective_start: start} = notice, now, policy) do
    DateTime.compare(start, now) != :gt and
      DateTime.compare(now, effective_end(notice, policy)) == :lt
  end
end
