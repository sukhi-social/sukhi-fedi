# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiDelivery.Push.Worker do
  @moduledoc """
  Ring one doorbell.

  The gateway already decided this push may interrupt this person
  (`SukhiFedi.Addons.WebPush.deliverable?/3` — the single predicate, and
  the only place that decision is made). By the time a job reaches here
  the question is settled; this module only carries the message.

  It runs on the delivery node because a push POST is outbound HTTP, and
  all outbound HTTP lives here (ARCHITECTURE §2.1). The gateway enqueues
  by worker *name*, so it doesn't need this module's code.

  Design: `docs/WEBPUSH.md` §3.
  """

  use Oban.Worker, queue: :push, max_attempts: 5

  alias SukhiDelivery.Repo
  alias WebPush.Subscription

  require Logger

  import Ecto.Query

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    %{
      "subscription_id" => subscription_id,
      "endpoint" => endpoint,
      "p256dh_key" => p256dh,
      "auth_key" => auth,
      "payload" => payload
    } = args

    sub = %Subscription{endpoint: endpoint, p256dh: p256dh, auth: auth}

    opts =
      [ttl: ttl(), urgency: urgency(), finch: SukhiDelivery.Finch] ++
        case args["topic"] do
          t when is_binary(t) and t != "" -> [topic: t]
          _ -> []
        end

    case WebPush.send(sub, payload, opts) do
      :ok ->
        :ok

      # 404/410: the browser revoked this endpoint, permanently. RFC 8030
      # says stop, and keeping the row would mean POSTing to a tombstone
      # forever.
      #
      # This is the one place push deletes anything, and it is right to do
      # it silently: a push subscription is browser↔us plumbing with no AP
      # representation, so FEDERATION.md's "any deletion MUST federate a
      # Delete" does not reach it. There is no remote that knows this row
      # exists and no `Undo` that would mean anything. Said out loud so a
      # future reader doesn't pattern-match delete → must federate and add
      # a phantom activity.
      {:error, :gone} ->
        forget(subscription_id)
        :ok

      # Anything else is transient until Oban's attempt cap says otherwise.
      # When it gives up, the *push* is dropped and the notification row is
      # untouched — the truth is still in the list. That is the recoverable
      # side of the trade.
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp forget(subscription_id) when is_integer(subscription_id) do
    {n, _} =
      Repo.delete_all(
        from p in "push_subscriptions",
          where: p.id == ^subscription_id
      )

    if n > 0, do: Logger.info("[push] dropped a revoked subscription")
    :ok
  end

  defp forget(_), do: :ok

  # How long a push service may hold this before giving up. A knock that
  # arrives a day late is not a knock, and the event is in the list anyway.
  defp ttl, do: Application.get_env(:sukhi_delivery, :push_ttl, 3600)

  # RFC 8030 §5.3. `normal` is the gentle setting, not a middling one:
  # the RFC's own example for it is "chat or calendar messages", while
  # `high` is "incoming phone calls or time-sensitive alerts" — the class
  # that gets through on a dying battery. Choosing not to be `high` is the
  # calm decision here.
  #
  # `low` reads like the quieter choice and isn't: it means "deliver when
  # the device is on power *or* Wi-Fi", so someone speaking to you could
  # wait until the phone is plugged in. A knock that only arrives on a
  # charger isn't a knock either.
  defp urgency, do: Application.get_env(:sukhi_delivery, :push_urgency, "normal")
end
