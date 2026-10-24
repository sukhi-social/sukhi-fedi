# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiDelivery.Outbox.Consumer do
  @moduledoc """
  Turns one `sns.outbox.*` event into one or more Oban delivery jobs.

  ## Subject coverage

      sns.outbox.note.created       → Bun `note` translator   → fan out
      sns.outbox.note.deleted       → Bun `delete` translator → fan out
      sns.outbox.dm.created         → Bun `dm` translator     → direct recipient inboxes
      sns.outbox.follow.requested   → Bun `follow` translator → followee inbox
      sns.outbox.quote.requested    → `quote_request` (FEP-044f)→ quoted author inbox
      sns.outbox.follow.undone      → Bun `undo` (Follow)     → followee inbox
      sns.outbox.like.created       → Bun `like` translator   → note author + relays
      sns.outbox.like.undone        → Bun `undo` (Like)       → note author
      sns.outbox.reaction.created   → Bun `emoji_react`       → note author + relays
      sns.outbox.reaction.undone    → Bun `undo` (EmojiReact) → note author
      sns.outbox.announce.created   → Bun `announce`          → note author + followers
                                      （板から出るぶんは板の followers へ）
      sns.outbox.announce.undone    → Bun `undo` (Announce)   → note author + followers
      sns.outbox.add.created        → Bun `add` (featured)    → followers
      sns.outbox.remove.created     → Bun `remove` (featured) → followers
      sns.outbox.follow.backfill    → Bun `note` translator   → single new-follower inbox
      sns.outbox.move.created       → `move` translator       → followers (account migration)

      sns.outbox.actor.updated      → AP.ActorJson Update(Person)  → followers + relays

  Ignored:
    * `sns.outbox.oauth.app_registered` — local-only, no federation

  ## Retries

  This module is the *dispatch* surface. Getting here — and the retry
  budget — belongs to `SukhiDelivery.Outbox.DispatchWorker`, one Oban
  job per `outbox` row.

  Return values inform that worker's retry policy: anything that could
  succeed on retry returns `:translate_failed` or `:crashed` (the job
  errors, Oban retries it on a backoff, and after 12 attempts it rests
  in `discarded`); structural problems (`:missing_*`, `:no_*`,
  `:bad_json`, `:ignored`, `:no_handler`) return immediately — the job
  is done, retry can't help.

  ## Recipient inbox resolution

  Local actor (`actor_uri` host == ours) → `<actor_uri>/inbox`
  (no network hop). Remote actor → `Federation.ActorFetcher.inbox_for/1`,
  which prefers `endpoints.sharedInbox` then `inbox` from the
  remote's actor JSON and falls back to the convention.
  """

  require Logger

  alias SukhiDelivery.Outbox.Handlers.{Notes, Social}

  @doc false
  def handle_event(subject, body) when is_binary(subject) and is_binary(body) do
    case JSON.decode(body) do
      {:ok, payload} when is_map(payload) ->
        try do
          dispatch(subject, payload)
        rescue
          e ->
            Logger.error(
              "Outbox.Consumer dispatch crash subject=#{subject}: " <>
                Exception.format(:error, e, __STACKTRACE__)
            )

            :crashed
        end

      _ ->
        Logger.warning("Outbox.Consumer: malformed JSON for #{subject}")
        :bad_json
    end
  end

  @doc false
  def dispatch("sns.outbox.note.created", p), do: Notes.created(p)
  def dispatch("sns.outbox.note.updated", p), do: Notes.updated(p)
  def dispatch("sns.outbox.note.deleted", p), do: Notes.deleted(p)
  def dispatch("sns.outbox.vote.created", p), do: Notes.vote(p)
  def dispatch("sns.outbox.dm.created", p), do: Notes.dm(p)
  def dispatch("sns.outbox.quote.requested", p), do: Notes.quote_requested(p)
  def dispatch("sns.outbox.follow.requested", p), do: Social.follow(p, :create)
  def dispatch("sns.outbox.follow.undone", p), do: Social.follow(p, :undo)
  def dispatch("sns.outbox.like.created", p), do: Social.like(p, :create)
  def dispatch("sns.outbox.like.undone", p), do: Social.like(p, :undo)
  def dispatch("sns.outbox.reaction.created", p), do: Social.reaction(p, :create)
  def dispatch("sns.outbox.reaction.undone", p), do: Social.reaction(p, :undo)
  def dispatch("sns.outbox.announce.created", p), do: Social.announce(p, :create)
  def dispatch("sns.outbox.announce.undone", p), do: Social.announce(p, :undo)
  def dispatch("sns.outbox.add.created", p), do: Social.collection_op(p, :add)
  def dispatch("sns.outbox.remove.created", p), do: Social.collection_op(p, :remove)
  def dispatch("sns.outbox.follow.backfill", p), do: Notes.follow_backfill(p)
  def dispatch("sns.outbox.move.created", p), do: Social.move(p)

  def dispatch("sns.outbox.actor.updated", p), do: Social.actor_updated(p)

  def dispatch("sns.outbox.oauth.app_registered", _p) do
    # local audit only — no federation
    :ignored
  end

  def dispatch(subject, _p) do
    Logger.debug("Outbox.Consumer: no handler for subject #{subject}")
    :no_handler
  end
end
