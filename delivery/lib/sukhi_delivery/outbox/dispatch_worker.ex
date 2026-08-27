# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiDelivery.Outbox.DispatchWorker do
  @moduledoc """
  Turns one `outbox` row into Oban delivery jobs.

  `SukhiDelivery.Outbox.Relay` inserts one of these per pending outbox
  row, inside the same transaction that flips the row to `published` —
  so there is no window in which a row is marked done but nothing is
  queued to act on it. That atomicity is the reason this step lives in
  Postgres: a hop through a separate broker is always a dual write.

  Routing and side effects live in `SukhiDelivery.Outbox.Consumer`; this
  module owns the retry policy:

    * structural results (`:ok`, `:no_recipients`, `:ignored`,
      `:no_handler`, `:no_actor`, `:no_followee`, `:missing_account`,
      `:missing_fields`, `:bad_json`) — done. Retry can't help.
    * transient results (`:translate_failed`, `:crashed`) — the
      translator (the gateway's native `fedify.*` service) is the only
      signer, so a gateway restart or OOM makes *every* outbound activity
      fail to translate for a few seconds. Those come back as
      `{:error, _}` so Oban retries them on `backoff/1`: 11 spaced
      attempts over ~27 minutes.

  After `@max_attempts` the job stops retrying and stays in Oban's
  `discarded` state — that is the dead-letter shelf. `args` still holds
  the whole event, so one can be inspected and re-run with
  `Oban.retry_job/1`. The Pruner is configured to leave `discarded`
  alone (see `config/config.exs`), so nothing sweeps it out from under us.
  """

  use Oban.Worker, queue: :outbox_dispatch, max_attempts: 12

  alias SukhiDelivery.Outbox.Consumer

  @transient [:translate_failed, :crashed]

  # Seconds to wait before the retry following the n-th attempt. The last
  # value repeats; with `max_attempts: 12` the 12th failure discards.
  @backoff_s [5, 10, 20, 40, 60, 120, 180, 300, 300, 300, 300]

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"subject" => subject, "payload" => payload}}) do
    case Consumer.handle_event(subject, JSON.encode!(payload)) do
      result when result in @transient -> {:error, result}
      _ -> :ok
    end
  end

  @doc "Backoff in seconds before the retry following `attempt` (1-based)."
  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: attempt}) when attempt >= 1 do
    Enum.at(@backoff_s, min(attempt, length(@backoff_s)) - 1)
  end

  @doc false
  def max_attempts, do: 12
end
