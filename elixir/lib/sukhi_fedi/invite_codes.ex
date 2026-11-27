# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.InviteCodes do
  @moduledoc """
  Invite-code context. The admin UI calls `issue/2` to mint a code; the
  signup API calls `consume/2` inside the registration transaction.

  A code is live while `uses_count < max_uses` and (if `expires_at` is
  set) it hasn't passed. `max_uses` is at least 1, so the default is the
  old single-use code; a larger cap lets several people join on one code,
  and every joiner is recorded in `invite_code_uses`.

  A code can also be issued *on behalf of* another local account
  (`on_behalf_of_id`): `issued_by` stays the admin who minted it (audit),
  but `preview/1` greets the visitor in the represented account's name —
  "@that_user invited you" — so an admin can hand someone an invite that
  carries that someone's authority.
  """

  import Ecto.Query

  alias SukhiFedi.AccountRepo
  alias SukhiFedi.Schema.{Account, InviteCode, InviteCodeUse}

  @code_bytes 9

  @doc """
  Mint a code. Options:

    * `:on_behalf_of_id` — attribute the invite to this account (nil = the
      issuer's own name)
    * `:max_uses` — how many people may join on it (>= 1, default 1)
    * `:note`, `:expires_at`
  """
  @spec issue(Account.t() | integer(), keyword()) :: {:ok, InviteCode.t()}
  def issue(issued_by, opts \\ [])
  def issue(%Account{id: id}, opts), do: issue(id, opts)

  def issue(issued_by_id, opts) when is_integer(issued_by_id) do
    attrs = %{
      code: generate_code(),
      issued_by_id: issued_by_id,
      on_behalf_of_id: opts[:on_behalf_of_id],
      # Floor at 1 here too — a caller's typo (0, negative) must never
      # mint a code that's born exhausted.
      max_uses: max(opts[:max_uses] || 1, 1),
      uses_count: 0,
      note: opts[:note],
      expires_at: opts[:expires_at]
    }

    %InviteCode{}
    |> Ecto.Changeset.cast(attrs, [
      :code,
      :issued_by_id,
      :on_behalf_of_id,
      :max_uses,
      :uses_count,
      :note,
      :expires_at
    ])
    |> Ecto.Changeset.validate_required([:code, :max_uses])
    |> AccountRepo.insert()
  end

  @spec list(keyword()) :: [InviteCode.t()]
  def list(opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)

    from(c in InviteCode, order_by: [desc: c.id], limit: ^limit)
    |> AccountRepo.all()
    |> AccountRepo.preload([:issued_by, :on_behalf_of, uses: :account])
  end

  @doc """
  Atomically claim one use of a code for `consumer_id`. Returns:

    * `{:ok, invite}` on success
    * `{:error, :invalid}` if no such code
    * `{:error, :already_used}` if the code is exhausted (`uses_count`
      has reached `max_uses`)
    * `{:error, :expired}` if past `expires_at`

  Intended to be called inside the signup `AccountRepo.transaction/1` so a
  failed account insert rolls the claim back.
  """
  @spec consume(String.t(), integer()) ::
          {:ok, InviteCode.t()} | {:error, :invalid | :already_used | :expired}
  def consume(code, consumer_id) when is_binary(code) and is_integer(consumer_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    case AccountRepo.get_by(InviteCode, code: code) do
      nil ->
        {:error, :invalid}

      %InviteCode{} = ic ->
        case classify(ic, now) do
          :ok -> claim(ic, consumer_id, now)
          err -> {:error, err}
        end
    end
  end

  @doc """
  Read a code's liveness without claiming a use. The `/invite/:code`
  landing page calls this (over RPC) to greet a visitor before signup —
  it reports who the invite is attributed to but leaves `uses_count`
  untouched; the actual claim still happens inside the signup transaction
  via `consume/2`.

  The greeting uses the represented account when the code was issued on
  someone's behalf, otherwise the issuer.

    * `{:ok, %{issuer_handle: ..., issuer_display_name: ...}}` when live
    * `{:error, :invalid | :already_used | :expired}` otherwise
  """
  @spec preview(String.t()) ::
          {:ok, %{issuer_handle: String.t() | nil, issuer_display_name: String.t() | nil}}
          | {:error, :invalid | :already_used | :expired}
  def preview(code) when is_binary(code) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    case AccountRepo.get_by(InviteCode, code: code) do
      nil ->
        {:error, :invalid}

      %InviteCode{} = ic ->
        case classify(ic, now) do
          :ok ->
            %{issued_by: issuer, on_behalf_of: behalf} =
              AccountRepo.preload(ic, [:issued_by, :on_behalf_of])

            who = behalf || issuer

            {:ok,
             %{
               issuer_handle: who && who.username,
               issuer_display_name: who && who.display_name
             }}

          err ->
            {:error, err}
        end
    end
  end

  # コードの生死を「読むだけ」で分類する ─ consume はこれが :ok のときだけ
  # atomic UPDATE に進み、preview はこれをそのまま返す。生死の判定を一箇所に
  # 集めて、consume と preview で二度書かない。
  defp classify(%InviteCode{} = ic, now) do
    cond do
      expired?(ic, now) -> :expired
      ic.uses_count >= ic.max_uses -> :already_used
      true -> :ok
    end
  end

  defp expired?(%InviteCode{expires_at: %DateTime{} = exp}, now),
    do: DateTime.compare(exp, now) != :gt

  defp expired?(%InviteCode{}, _now), do: false

  # Atomic claim: a conditional UPDATE that bumps `uses_count` only while
  # it's below `max_uses` and the code hasn't expired. Under concurrent
  # signups Postgres serializes the row and re-checks the guard against
  # the freshly-committed count, so exactly `max_uses` claims win; the
  # losers affect zero rows and get `:already_used`, rolling back their
  # account insert (no over-spend, no TOCTOU double-spend). The joiner row
  # is written in the same transaction, so the count and the "who joined"
  # commit together.
  defp claim(%InviteCode{id: id} = ic, consumer_id, now) do
    {n, _} =
      from(c in InviteCode,
        where:
          c.id == ^id and c.uses_count < c.max_uses and
            (is_nil(c.expires_at) or c.expires_at > ^now)
      )
      |> AccountRepo.update_all(inc: [uses_count: 1])

    case n do
      1 ->
        %InviteCodeUse{}
        |> Ecto.Changeset.change(invite_code_id: id, account_id: consumer_id, used_at: now)
        |> AccountRepo.insert!()

        {:ok, %{ic | uses_count: ic.uses_count + 1}}

      _ ->
        {:error, :already_used}
    end
  end

  defp generate_code do
    :crypto.strong_rand_bytes(@code_bytes)
    |> Base.encode32(case: :lower, padding: false)
  end
end
