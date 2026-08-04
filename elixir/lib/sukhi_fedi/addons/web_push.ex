# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Addons.WebPush do
  @moduledoc """
  Web Push — the one transport that can wake a person who isn't looking.

  Everything else this server renders (the SSE count, the NotifGlyph
  silhouette) only moves for someone already on the page. A push buzzes
  a pocket. So the whole question is *which notifications have earned
  the right to interrupt a life*, and the answer lives in exactly one
  place here: `deliverable?/3`. The send path has no other door.

  This node decides and enqueues; the delivery node does the outbound
  HTTP (ARCHITECTURE §2.1 — all outbound HTTP lives there).

  Design: `docs/WEBPUSH.md`.
  """

  use SukhiFedi.Addon, id: :web_push

  import Ecto.Query
  alias SukhiFedi.Repo
  alias SukhiFedi.Schema.{Account, Notification, PushSubscription}

  require Logger

  # ── The calm contract, stated once ──────────────────────────────────────
  #
  # Only these may ever reach a push transport. **Nothing is added here
  # without re-reading docs/WEBPUSH.md §7** — putting `favourite` in this
  # list is precisely the FOMO regression the two-tier model exists to
  # prevent. The rest (favourite, reblog, follow, poll, update…) are the
  # 景色: they grow a silhouette at a navigation boundary, they do not
  # wake anybody.
  #
  # This list is canonical. The web client's `DIRECT_TYPES` reads it from
  # the server rather than keeping its own copy — the decision that gates
  # a phone buzz should live next to the code that buzzes it.
  @direct_types ["mention", "follow_request"]

  @doc "The notification types allowed to interrupt. The client reads this."
  @spec direct_types() :: [String.t()]
  def direct_types, do: @direct_types

  # ── Subscriptions ───────────────────────────────────────────────────────

  def subscribe(account_id, endpoint, p256dh_key, auth_key, alerts \\ %{}) do
    %PushSubscription{
      account_id: account_id,
      endpoint: endpoint,
      p256dh_key: p256dh_key,
      auth_key: auth_key,
      alerts: alerts
    }
    |> Repo.insert(
      on_conflict: {:replace, [:account_id, :p256dh_key, :auth_key, :alerts, :updated_at]},
      conflict_target: :endpoint
    )
  end

  def unsubscribe(endpoint) do
    Repo.delete_all(from p in PushSubscription, where: p.endpoint == ^endpoint)
  end

  def get_subscriptions(account_id) do
    Repo.all(from p in PushSubscription, where: p.account_id == ^account_id)
  end

  @doc """
  Mastodon's API expects one subscription per access token, but our
  schema is per (account, endpoint). For now we surface the most
  recent subscription for the account — clients re-POST whenever the
  browser hands them a new endpoint, so "newest" is a reasonable
  proxy.
  """
  def get_subscription_for(account_id) when is_integer(account_id) do
    Repo.one(
      from p in PushSubscription,
        where: p.account_id == ^account_id,
        order_by: [desc: p.id],
        limit: 1
    )
  end

  @doc """
  Server VAPID key the client needs to encrypt push messages with.
  Returned by `GET /api/v1/instance` (under `configuration.urls`) and
  by `POST /api/v1/push/subscription` on success. nil if unconfigured.
  """
  def server_key, do: config()[:public_key]

  @doc "True when a VAPID keypair is configured. Push is off without one."
  def configured?, do: is_binary(server_key()) and server_key() != ""

  # ── The one predicate ───────────────────────────────────────────────────

  @doc """
  May this notification interrupt this person, right now?

  Pure: `now` and `quiet_until` come in as arguments so there is no clock
  read and no `Repo` call inside, and so it can be unit-tested and called
  anywhere. This is read *after* the notification row is already written
  and streamed — it changes what buzzes a phone, never what the list
  truthfully contains.
  """
  @spec deliverable?(String.t(), map(), %{
          quiet_until: DateTime.t() | nil,
          now: DateTime.t()
        }) :: boolean()
  def deliverable?(type, alerts, %{quiet_until: quiet_until, now: now}) do
    interruptible_tier?(type) and alert_enabled?(type, alerts) and
      not quiet?(quiet_until, now)
  end

  defp interruptible_tier?(type), do: type in @direct_types

  # The user's own switch. A type they turned off is never pushed even if
  # it is `direct`. Absence is not consent, so a key the client never sent
  # defaults to *off*; `== true` normalizes the untrusted truthiness once,
  # strictly, at the edge (the alerts map arrived as client JSON).
  defp alert_enabled?(type, alerts) when is_map(alerts), do: Map.get(alerts, type) == true
  defp alert_enabled?(_type, _alerts), do: false

  defp quiet?(nil, _now), do: false
  defp quiet?(%DateTime{} = until, now), do: DateTime.compare(now, until) == :lt

  # ── Fan-out ─────────────────────────────────────────────────────────────

  @doc """
  Ring the doorbell for a freshly-written notification.

  Best-effort *to enqueue* and off the caller's path — a push that can't
  be queued must never fail the write that produced the notification.
  But once enqueued, delivery is durable (the delivery node's Oban queue
  retries with backoff).
  """
  @spec notify(Notification.t()) :: :ok
  def notify(%Notification{} = notif) do
    if configured?() and interruptible_tier?(notif.type) do
      do_notify(notif)
    end

    :ok
  rescue
    # The doorbell is never allowed to break the house — but it must say
    # so when it breaks. This rescue once hid a wrong Oban instance name:
    # every push vanished, `notify/1` returned `:ok`, and there was
    # nothing in the log to find. Log the stacktrace, not just the
    # message, so the next one is one grep away.
    error ->
      Logger.error("""
      web push enqueue failed — nothing was sent for notification \
      #{inspect(Map.get(notif, :id))}: #{Exception.message(error)}
      #{Exception.format_stacktrace(__STACKTRACE__)}\
      """)

      :ok
  end

  def notify(_), do: :ok

  defp do_notify(notif) do
    now = DateTime.utc_now()

    # One query, not one per subscription: the subscriptions and the
    # recipient's quiet-state come back together.
    rows =
      Repo.all(
        from p in PushSubscription,
          join: a in Account,
          on: a.id == p.account_id,
          where: p.account_id == ^notif.account_id,
          select: %{
            id: p.id,
            endpoint: p.endpoint,
            p256dh_key: p.p256dh_key,
            auth_key: p.auth_key,
            alerts: p.alerts,
            quiet_until: a.quiet_until
          }
      )

    payload = payload_for(notif)

    for row <- rows,
        deliverable?(notif.type, row.alerts || %{}, %{quiet_until: row.quiet_until, now: now}) do
      enqueue(row, payload, topic_for(row, notif))
    end
  end

  @doc """
  The RFC 8030 `Topic` for this knock.

  A push service replaces a *pending* message that carries the same topic
  on the same subscription. So ten messages from one person while a phone
  is asleep become one buzz, decided upstream — the device never wakes
  nine times to be told the same thing.

  (This is not the service worker's `tag`, which stacks notifications
  already *shown* on the device. That one can't help while the phone is
  off; this one is the half that can.)

  It is a keyed digest, not `mention-42`. The topic travels as a plain
  header — the push service reads it even though the body is ciphertext —
  and a legible one would hand a third party "account 42 messages you,
  here is how often". A stable token is unavoidable, because collapsing
  *is* recognising sameness; making it opaque is the part we can choose.
  Keyed with the subscription's own auth secret, so it is neither
  guessable nor comparable across devices.
  """
  @spec topic_for(map(), Notification.t()) :: String.t()
  def topic_for(row, %Notification{} = notif) do
    # Collapse per (sender, kind): a burst from one person folds into one
    # knock, while a follow request from someone else still gets its own.
    key = "#{notif.type}:#{notif.from_account_id}"

    :hmac
    |> :crypto.mac(:sha256, row.auth_key || "", key)
    # RFC 8030 §5.4 caps Topic at 32 url-safe characters; 16 is plenty and
    # leaves the shape unmistakably opaque.
    |> binary_part(0, 12)
    |> Base.url_encode64(padding: false)
  end

  @doc """
  What the service worker gets. **The minimum**: enough to say "someone
  spoke to you" and open the right thread.

  Deliberately not in here: the note body, media, a content preview, or a
  badge count. (a) the push service learns nothing even though it is
  ciphertext-blind; (b) a lock-screen preview of a DM is a leak the
  recipient never opted into; (c) a push is a knock, not the message
  shoved in your face — the words wait, calmly, in the app. A count on an
  app icon would be the FOMO number the ambient tier exists to avoid.
  """
  @spec payload_for(Notification.t()) :: map()
  def payload_for(%Notification{} = notif) do
    %{
      notification_id: notif.id,
      notification_type: notif.type,
      # Who, by handle — no display name, no avatar, no body.
      from: from_acct(notif.from_account_id),
      note_id: notif.note_id
    }
  end

  defp from_acct(nil), do: nil

  defp from_acct(account_id) do
    Repo.one(from a in Account, where: a.id == ^account_id, select: a.username)
  end

  # The delivery node owns outbound HTTP, so the job names a module that
  # only exists over there. Oban takes a worker name as a string precisely
  # so a producer needn't carry the consumer's code.
  #
  # **`SukhiFedi.Oban`, not `Oban`.** This app runs its Oban under a name
  # (application.ex), so the bare `Oban.insert/1` looks for a default
  # instance that isn't there and raises — which `notify/1`'s rescue then
  # swallowed. Every push was quietly dropped: `:ok` returned, nothing
  # logged, nothing sent. Exactly the silent lie the round-trip test was
  # written to prevent, arriving through a different door.
  defp enqueue(row, payload, topic) do
    %{
      "subscription_id" => row.id,
      "endpoint" => row.endpoint,
      "p256dh_key" => row.p256dh_key,
      "auth_key" => row.auth_key,
      "payload" => payload,
      "topic" => topic
    }
    |> Oban.Job.new(worker: "SukhiDelivery.Push.Worker", queue: :push, max_attempts: 5)
    |> then(&Oban.insert(SukhiFedi.Oban, &1))
  end

  defp config, do: Application.get_env(:sukhi_fedi, :web_push, [])
end
