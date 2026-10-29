# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.AccountDeletion do
  @moduledoc """
  Closing an account — as easy as opening one.

  The decisions (docs/MUZAI_NO_SHICHISE.md §房舎施):

    * **One day's grace.** `request/1` books the closing for 24
      hours later. Until then the owner can `cancel/1` by signing in; nothing
      is sent to the fediverse during the grace.
    * **A mail at both ends** — when it is booked and when it is done — to
      the verified address, if there is one.
    * **The handle is retired for good.** The `accounts` row is kept with
      `deleted_at` set, so the local-username unique index refuses the name
      forever, to everyone. Every personal column is blanked.

  `finish_step/1` (driven by `AccountDeletion.Worker`) does the closing in
  small steps: first the account stops being usable (credentials, sessions,
  tokens, profile gone, in one transaction), then its notes go in batches —
  each through the same `Notes.Create.delete_note_for_cleanup/3` that
  self-cleanup uses, so every `Delete(Note)` federates — and last one
  actor `Delete`, enqueued with the "finished" mark in one transaction.

  Follow rows are kept on purpose: the actor `Delete` is fanned out to
  the followers' inboxes *after* this runs, and reads them.
  """

  import Ecto.Query

  alias SukhiFedi.{Mailer, Outbox, Repo}
  alias SukhiFedi.Notes.Create
  alias SukhiFedi.Schema.{Account, AccountDeletion, Note}

  @grace_seconds 86_400
  @batch 50

  @spec grace_seconds() :: pos_integer()
  def grace_seconds, do: @grace_seconds

  @doc "The live request for this account, or `nil`."
  @spec pending(Account.t() | integer()) :: AccountDeletion.t() | nil
  def pending(%Account{id: id}), do: pending(id)

  def pending(account_id) when is_integer(account_id) do
    Repo.one(from(d in live(), where: d.account_id == ^account_id, limit: 1))
  end

  @doc """
  Book the closing for one day from `now`. Asking again while one is
  booked returns the booking as it is (the clock is not pushed back).
  """
  @spec request(Account.t(), DateTime.t()) ::
          {:ok, AccountDeletion.t()} | {:error, :closed | :remote}
  def request(account, now \\ now())

  def request(%Account{deleted_at: %DateTime{}}, _now), do: {:error, :closed}
  def request(%Account{domain: d}, _now) when is_binary(d), do: {:error, :remote}

  def request(%Account{id: id} = account, %DateTime{} = now) do
    case pending(id) do
      %AccountDeletion{} = d ->
        {:ok, d}

      nil ->
        row = %AccountDeletion{
          account_id: id,
          requested_at: now,
          scheduled_for: DateTime.add(now, @grace_seconds, :second)
        }

        case Repo.insert(row, on_conflict: :nothing) do
          {:ok, %AccountDeletion{id: nil}} ->
            {:ok, pending(id)}

          {:ok, d} ->
            mail_requested(account, d)
            {:ok, d}
        end
    end
  end

  @doc "Take the request back. Only possible before the work has started."
  @spec cancel(Account.t(), DateTime.t()) :: :ok | {:error, :none | :started}
  def cancel(%Account{id: id}, now \\ now()) do
    case pending(id) do
      nil ->
        {:error, :none}

      %AccountDeletion{started_at: %DateTime{}} ->
        {:error, :started}

      %AccountDeletion{} = d ->
        {1, _} =
          Repo.update_all(from(x in AccountDeletion, where: x.id == ^d.id),
            set: [cancelled_at: now]
          )

        :ok
    end
  end

  @doc "Requests whose day is up (or that are already under way)."
  @spec due(DateTime.t()) :: [AccountDeletion.t()]
  def due(now \\ now()) do
    Repo.all(
      from(d in live(),
        where: d.scheduled_for <= ^now or not is_nil(d.started_at),
        order_by: d.id
      )
    )
  end

  @doc """
  One step of the closing. `:more` means call again; `:done` means the
  account is closed and the actor `Delete` is queued.
  """
  @spec finish_step(AccountDeletion.t(), DateTime.t()) :: :more | :done | {:error, term()}
  def finish_step(%AccountDeletion{} = d, now \\ now()) do
    d = Repo.get!(AccountDeletion, d.id)

    cond do
      d.finished_at != nil or d.cancelled_at != nil -> :done
      d.started_at == nil -> start(d, now)
      true -> next_notes_or_finish(d, now)
    end
  end

  # ── steps ────────────────────────────────────────────────────────────────

  # The account stops being usable *now*, in one transaction. The address is
  # read first (the mail is sent to it afterwards) and then blanked.
  defp start(%AccountDeletion{} = d, now) do
    account = Repo.get!(Account, d.account_id)
    email = if account.email_verified_at, do: account.email

    Repo.transaction(fn ->
      Repo.update_all(from(x in AccountDeletion, where: x.id == ^d.id), set: [started_at: now])
      blank(account.id, now)
    end)

    if is_binary(email), do: mail_done(email, account.username)
    :more
  end

  defp blank(account_id, now) do
    for {schema, field} <- [
          {SukhiFedi.Schema.Session, :account_id},
          {SukhiFedi.Schema.OauthAccessToken, :account_id},
          {SukhiFedi.Schema.OauthAuthorizationCode, :account_id},
          {SukhiFedi.Schema.PushSubscription, :account_id},
          {SukhiFedi.Schema.WebauthnCredential, :account_id},
          {SukhiFedi.Schema.EmailCode, :account_id},
          {SukhiFedi.Schema.PinnedNote, :account_id},
          {SukhiFedi.Schema.Bookmark, :account_id},
          {SukhiFedi.Schema.Mute, :account_id},
          {SukhiFedi.Schema.Block, :account_id},
          {SukhiFedi.Schema.NoteDraft, :account_id},
          {SukhiFedi.Schema.ScheduledStatus, :account_id},
          {SukhiFedi.Schema.Marker, :account_id},
          {SukhiFedi.Schema.Notification, :account_id}
        ] do
      Repo.delete_all(from(r in schema, where: field(r, ^field) == ^account_id))
    end

    Repo.update_all(from(a in Account, where: a.id == ^account_id),
      set: [
        deleted_at: now,
        email: nil,
        email_verified_at: nil,
        password_hash: nil,
        totp_secret: nil,
        totp_enabled_at: nil,
        summary: nil,
        summary_source: nil,
        fields: [],
        avatar_url: nil,
        banner_url: nil,
        avatar_decorations: [],
        location: nil,
        birthday: nil,
        aliases: [],
        quiet_until: nil,
        locked: false,
        discoverable: false,
        indexable: false
      ]
    )
  end

  defp next_notes_or_finish(%AccountDeletion{} = d, now) do
    ids =
      Repo.all(
        from(n in Note,
          where: n.account_id == ^d.account_id,
          order_by: n.id,
          limit: ^@batch,
          select: n.id
        )
      )

    case ids do
      [] ->
        finish(d, now)

      ids ->
        Enum.each(ids, fn id ->
          case Repo.get(Note, id) do
            %Note{} = note -> Create.delete_note_for_cleanup(note, now, "account_deleted")
            nil -> :ok
          end
        end)

        :more
    end
  end

  defp finish(%AccountDeletion{} = d, now) do
    account = Repo.get!(Account, d.account_id)

    Ecto.Multi.new()
    |> Ecto.Multi.update_all(
      :mark,
      from(x in AccountDeletion, where: x.id == ^d.id),
      set: [finished_at: now]
    )
    |> Outbox.enqueue_multi(
      :outbox_event,
      "sns.outbox.actor.deleted",
      "account",
      fn _ -> account.id end,
      fn _ -> %{account_id: account.id, username: account.username} end
    )
    |> Repo.transaction()
    |> case do
      {:ok, _} -> :done
      {:error, _, reason, _} -> {:error, reason}
    end
  end

  # ── mail ─────────────────────────────────────────────────────────────────

  defp mail_requested(%Account{email: email, email_verified_at: %DateTime{}, username: u}, d)
       when is_binary(email) do
    Mailer.deliver(email, "アカウントを閉じる、受けつけました", """
    @#{u} さん

    アカウントを閉じる、お願いを受けつけました。
    #{Calendar.strftime(d.scheduled_for, "%Y-%m-%d %H:%M")} (UTC) ごろ、閉じます。
    それまでは、ログインして、設定の「アカウントを閉じる」から、取り消せます。

    心当たりがないときも、同じ場所から取り消せます。
    閉じたあとは、ハンドル @#{u} は、だれも使えなくなります。

    sukhi
    """)
  end

  defp mail_requested(_account, _d), do: :ok

  defp mail_done(email, username) do
    Mailer.deliver(email, "アカウントを閉じました", """
    @#{username} さん

    アカウントを閉じました。投稿は消え、連合先のサーバにも「忘れて」とお願いを送りました。
    ハンドル @#{username} は、ずっと空けておきます。

    いままで、ここにいてくれて、ありがとう。
    また会えたら、うれしいです。

    sukhi
    """)
  end

  # ── helpers ──────────────────────────────────────────────────────────────

  defp live do
    from(d in AccountDeletion, where: is_nil(d.cancelled_at) and is_nil(d.finished_at))
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
