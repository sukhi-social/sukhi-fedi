# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.JoinApplications do
  @moduledoc """
  Asking to join (docs/JOIN.md): write → receipt mail → "I got it" → edit link.

      submit/2        the application is saved; a receipt mail with the
                      receipt number only goes out; the browser gets a
                      *claim* (a secret) and the receipt number
      received/1      the browser that applied says it got the mail → the
                      edit link is mailed, once
      change_email/2  "no, I didn't": fix the address before anyone has
                      said yes; the receipt mail goes again
      fetch_by_key/1,
      edit/2          the person rewrites their words through the link
      purge_unconfirmed/1
                      an application nobody confirmed is deleted after
                      three hours

  Validation lives in `Schema.JoinApplication`; the per-address mail limit
  lives here (`send_mail?/1`), the per-peer limit at the gateway route.
  Both secrets are 192 random bits, stored only as sha256 — a leaked
  table opens nothing.
  """

  import Ecto.Query
  require Logger

  alias SukhiFedi.Repo
  alias SukhiFedi.JoinApplications.{CheckDay, Mail}
  alias SukhiFedi.Schema.JoinApplication

  @unconfirmed_ttl_seconds 3 * 3600
  # The entry link works for 14 days; after that they write again.
  @entry_ttl_seconds 14 * 24 * 3600
  # 3 mails per address per 15 minutes, the same ceiling `EmailAuth` keeps.
  @mail_per_address {3, 15 * 60 * 1000}
  @receipt_tries 8

  @type error ::
          {:error, :rate_limited | :send_failed | :not_found | :confirmed | Ecto.Changeset.t()}

  @doc "What the form shows before anyone writes: who looks, and on which day."
  @spec info(DateTime.t()) :: %{
          greeter: String.t() | nil,
          check_on: Date.t(),
          weekday: 1..7,
          days_after: pos_integer()
        }
  def info(now \\ DateTime.utc_now()) do
    check = CheckDay.next(now)

    %{
      greeter: CheckDay.greeter(),
      check_on: check.date,
      weekday: check.weekday,
      days_after: check.days_after
    }
  end

  @doc """
  Save the application and send the receipt. Returns the claim — the
  secret the browser keeps — the saved row, and the day it will be looked at. If the mail does not go
  out, nothing is kept.
  """
  @spec submit(map(), DateTime.t()) ::
          {:ok, %{application: JoinApplication.t(), claim: String.t()}} | error()
  def submit(attrs, now \\ DateTime.utc_now()) when is_map(attrs) do
    claim = secret()
    check = CheckDay.next(now)
    keys = %{receipt: new_receipt(), claim_hash: hash(claim), check_on: check.date}

    case JoinApplication.create_changeset(attrs, keys) do
      %Ecto.Changeset{valid?: false} = invalid -> {:error, invalid}
      %Ecto.Changeset{valid?: true} = valid -> store_and_send(valid, claim, check)
    end
  end

  defp store_and_send(changeset, claim, check) do
    with :ok <- allow_mail(Ecto.Changeset.get_field(changeset, :email)),
         {:ok, app} <- Repo.insert(changeset),
         :ok <- send_receipt(app, check) do
      {:ok, %{application: app, claim: claim, check: check}}
    else
      {:error, %Ecto.Changeset{}} = error -> error
      {:error, :rate_limited} = error -> error
      {:error, :send_failed, app} -> discard(app)
    end
  end

  @doc """
  "Yes, I got the mail." Mints the edit key, stores its hash, mails the
  link. Said twice, it does not mail twice.
  """
  @spec received(String.t()) :: {:ok, JoinApplication.t()} | error()
  def received(claim) do
    case by_claim(claim) do
      nil -> {:error, :not_found}
      %JoinApplication{confirmed_at: %DateTime{}} = app -> {:ok, app}
      %JoinApplication{} = app -> confirm(app)
    end
  end

  defp confirm(app) do
    key = secret()
    {:ok, confirmed} = app |> JoinApplication.confirm_changeset(hash(key)) |> Repo.update()

    case Mail.edit_link(confirmed.email, confirmed.receipt, key, confirmed.lang) do
      :ok ->
        {:ok, confirmed}

      {:error, _} ->
        {:ok, _} = confirmed |> JoinApplication.unconfirm_changeset() |> Repo.update()
        {:error, :send_failed}
    end
  end

  @doc """
  "No, I didn't get it": a corrected address, then the receipt again. Only
  until the first "yes" — after it the address belongs to the person who
  read the mail.
  """
  @spec change_email(String.t(), String.t()) :: {:ok, JoinApplication.t()} | error()
  def change_email(claim, email) do
    case by_claim(claim) do
      nil ->
        {:error, :not_found}

      %JoinApplication{confirmed_at: %DateTime{}} ->
        {:error, :confirmed}

      %JoinApplication{} = app ->
        case JoinApplication.email_changeset(app, %{"email" => email}) do
          %Ecto.Changeset{valid?: false} = invalid -> {:error, invalid}
          %Ecto.Changeset{valid?: true} = valid -> move_and_send(valid)
        end
    end
  end

  defp move_and_send(changeset) do
    with :ok <- allow_mail(Ecto.Changeset.get_field(changeset, :email)),
         {:ok, app} <- Repo.update(changeset),
         :ok <- send_receipt(app, CheckDay.next()) do
      {:ok, app}
    else
      {:error, %Ecto.Changeset{}} = error -> error
      {:error, :rate_limited} = error -> error
      {:error, :send_failed, _app} -> {:error, :send_failed}
    end
  end

  @doc "The application behind an edit key, or `:not_found`."
  @spec fetch_by_key(String.t()) :: {:ok, JoinApplication.t()} | {:error, :not_found}
  def fetch_by_key(key) do
    case by_edit_key(key) do
      nil -> {:error, :not_found}
      app -> {:ok, app}
    end
  end

  @doc "Rewrite the words, through the edit key."
  @spec edit(String.t(), map()) :: {:ok, JoinApplication.t()} | error()
  def edit(key, attrs) when is_map(attrs) do
    case by_edit_key(key) do
      nil -> {:error, :not_found}
      app -> app |> JoinApplication.edit_changeset(attrs) |> Repo.update()
    end
  end

  # ── step 2: the greeter reads, welcomes, or declines ─────────────────────

  @doc """
  Applications waiting for an answer: confirmed ("yes, I got the mail"),
  not yet welcomed, oldest first. Anything not confirmed is not here —
  the address may not be theirs.
  """
  @spec list_waiting() :: [JoinApplication.t()]
  def list_waiting do
    Repo.all(
      from(a in JoinApplication,
        where: not is_nil(a.confirmed_at) and is_nil(a.welcomed_at),
        order_by: [asc: a.created_at]
      )
    )
  end

  @doc "One waiting application, by receipt number (spaces and dashes are fine)."
  @spec fetch_waiting(String.t()) :: {:ok, JoinApplication.t()} | {:error, :not_found}
  def fetch_waiting(receipt) when is_binary(receipt) do
    case Repo.get_by(JoinApplication, receipt: String.replace(receipt, ~r/[\s-]/, "")) do
      %JoinApplication{confirmed_at: %DateTime{}, welcomed_at: nil} = app -> {:ok, app}
      _ -> {:error, :not_found}
    end
  end

  def fetch_waiting(_), do: {:error, :not_found}

  @doc """
  Welcome them. A one-time entry key is minted (only its hash is kept) and
  mailed as a link that works for 14 days; `note` is the greeter's one line
  and goes into the mail as written. Once the mail has gone, what they
  wrote and their address are erased. If the mail does not go, nothing
  changes.
  """
  @spec welcome(String.t(), String.t() | nil, integer(), DateTime.t()) ::
          {:ok, JoinApplication.t()} | {:error, :not_found | :send_failed | :too_long}
  def welcome(receipt, note, by_id, now \\ DateTime.utc_now()) when is_integer(by_id) do
    with {:ok, note} <- clean_line(note),
         {:ok, app} <- fetch_waiting(receipt) do
      key = secret()
      expires = DateTime.add(now, @entry_ttl_seconds, :second)
      {:ok, welcomed} = app |> JoinApplication.welcome_changeset(hash(key), expires) |> Repo.update()

      case Mail.welcome(welcomed.email, welcomed.call_name, key, note, welcomed.lang) do
        :ok ->
          {:ok, _} = welcomed |> JoinApplication.scrub_changeset() |> Repo.update()
          audit("join_welcomed", by_id, welcomed.receipt)
          {:ok, welcomed}

        {:error, _} ->
          {:ok, _} = welcomed |> JoinApplication.unwelcome_changeset() |> Repo.update()
          {:error, :send_failed}
      end
    end
  end

  @doc """
  Not this time. A gentle answer goes out (`reason`, if given, is in it as
  written), and then the application is deleted. If the mail does not go,
  the application stays.
  """
  @spec decline(String.t(), String.t() | nil, integer()) ::
          :ok | {:error, :not_found | :send_failed | :too_long}
  def decline(receipt, reason, by_id) when is_integer(by_id) do
    with {:ok, reason} <- clean_line(reason),
         {:ok, app} <- fetch_waiting(receipt) do
      case Mail.decline(app.email, app.call_name, reason, app.lang) do
        :ok ->
          {:ok, _} = Repo.delete(app)
          audit("join_declined", by_id, app.receipt)
          :ok

        {:error, _} ->
          {:error, :send_failed}
      end
    end
  end

  @doc """
  Is this entry key still good? For the page the link opens. Reads only;
  the key is spent by `consume_entry/2`, inside the sign-up.
  """
  @spec entry_status(String.t(), DateTime.t()) :: :ok | {:error, :invalid | :used | :expired}
  def entry_status(key, now \\ DateTime.utc_now()) do
    case by_entry_key(key) do
      nil -> {:error, :invalid}
      %JoinApplication{joined_at: %DateTime{}} -> {:error, :used}
      %JoinApplication{entry_expires_at: exp} -> if DateTime.compare(exp, now) == :gt, do: :ok, else: {:error, :expired}
    end
  end

  @doc """
  Spend the entry key, once. Meant for the sign-up's own transaction, so a
  sign-up that fails does not use it up; the conditional update is what
  keeps two sign-ups on one key from both getting in.
  """
  @spec consume_entry(String.t(), DateTime.t()) ::
          {:ok, JoinApplication.t()} | {:error, :invalid | :used | :expired}
  def consume_entry(key, now \\ DateTime.utc_now()) do
    now = DateTime.truncate(now, :second)

    with :ok <- entry_status(key, now) do
      h = hash(key)

      {n, _} =
        Repo.update_all(
          from(a in JoinApplication,
            where: a.entry_hash == ^h and is_nil(a.joined_at) and a.entry_expires_at > ^now
          ),
          set: [joined_at: now]
        )

      case n do
        1 -> {:ok, by_entry_key(key)}
        _ -> {:error, :used}
      end
    end
  end

  @doc "Delete applications nobody confirmed, written before `now - 3 hours`. Returns the count."
  @spec purge_unconfirmed(DateTime.t()) :: non_neg_integer()
  def purge_unconfirmed(now \\ DateTime.utc_now()) do
    cutoff = DateTime.add(now, -@unconfirmed_ttl_seconds, :second)

    {n, _} =
      Repo.delete_all(
        from(a in JoinApplication, where: is_nil(a.confirmed_at) and a.created_at < ^cutoff)
      )

    n
  end

  # ── internals ────────────────────────────────────────────────────────────

  # The greeter's one line (a welcome's note, a decline's reason) goes into
  # the mail as written. Trimmed; blank is nothing; this is the one place
  # that holds its length.
  @line_max 500
  defp clean_line(nil), do: {:ok, nil}

  defp clean_line(text) when is_binary(text) do
    case String.trim(text) do
      "" -> {:ok, nil}
      t when byte_size(t) > @line_max * 4 -> {:error, :too_long}
      t -> if String.length(t) > @line_max, do: {:error, :too_long}, else: {:ok, t}
    end
  end

  defp clean_line(_), do: {:error, :too_long}

  # Who answered which application, and how. The receipt number only: not
  # the words, not the address (they are gone or about to be).
  defp audit(action, admin_id, receipt) do
    case %{action: action, admin_account_id: admin_id, metadata: %{receipt: receipt}}
         |> SukhiFedi.Schema.AdminAudit.changeset()
         |> Repo.insert() do
      {:ok, _} -> :ok
      {:error, reason} -> Logger.warning("join audit not written (#{action}): #{inspect(reason)}")
    end
  end

  defp send_receipt(app, check) do
    case Mail.receipt(app.email, app.receipt, check, app.lang) do
      :ok -> :ok
      {:error, _} -> {:error, :send_failed, app}
    end
  end

  # A receipt that did not go out leaves nothing behind.
  defp discard(app) do
    _ = Repo.delete(app)
    {:error, :send_failed}
  end

  defp allow_mail(email) do
    {limit, scale} = @mail_per_address

    case Hammer.check_rate("join_mail:addr:#{email}", scale, limit) do
      {:allow, _} -> :ok
      {:deny, _} -> {:error, :rate_limited}
    end
  end

  defp by_claim(claim) when is_binary(claim) and claim != "",
    do: Repo.get_by(JoinApplication, claim_hash: hash(claim))

  defp by_claim(_), do: nil

  defp by_edit_key(key) when is_binary(key) and key != "",
    do: Repo.get_by(JoinApplication, edit_hash: hash(key))

  defp by_edit_key(_), do: nil

  defp by_entry_key(key) when is_binary(key) and key != "",
    do: Repo.get_by(JoinApplication, entry_hash: hash(key))

  defp by_entry_key(_), do: nil

  # Six digits, grouped on screen. Unique among the rows kept; the
  # unique index is the last word if two race.
  defp new_receipt(tries \\ @receipt_tries) do
    <<n::32>> = :crypto.strong_rand_bytes(4)
    receipt = n |> rem(1_000_000) |> Integer.to_string() |> String.pad_leading(6, "0")

    if tries > 1 and Repo.exists?(from(a in JoinApplication, where: a.receipt == ^receipt)),
      do: new_receipt(tries - 1),
      else: receipt
  end

  defp secret, do: :crypto.strong_rand_bytes(24) |> Base.url_encode64(padding: false)

  defp hash(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
end
