# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Notifications do
  @moduledoc """
  Mastodon notification index + writer.

  Reads back what `AP.Instructions` and the `Notes` / `Social` write
  paths emit. Idempotency is enforced by the (account_id, from_account_id,
  type, note_id) unique index — duplicate inserts return `:ok` and
  the existing row.

  Surface:

    * `list/2`   — paged read; honours Mastodon's `max_id` / `since_id` /
                   `min_id` / `limit` / `types[]` / `exclude_types[]`.
    * `get/2`    — single row, scoped to the viewer.
    * `clear/1`  — soft-bulk-dismiss every row for the viewer.
    * `dismiss/2`— soft-dismiss a single row.

  All three write helpers are short-circuited by `on_conflict: :nothing`
  so callers don't have to know whether a duplicate would slip through
  Multi steps.
  """

  import Ecto.Query

  alias SukhiFedi.Repo
  alias SukhiFedi.Addons.Moderation
  alias SukhiFedi.Schema.{Account, Notification}

  @default_limit 15
  @max_limit 30

  @doc """
  Insert a notification, idempotent on (recipient, actor, type, note).

  Returns `{:ok, %Notification{}}` for both fresh inserts and conflicts.
  No-op when `account_id == from_account_id` (you don't notify
  yourself).
  """
  @spec create(map()) :: {:ok, Notification.t()} | {:error, Ecto.Changeset.t()}
  def create(%{account_id: rid, from_account_id: aid}) when rid == aid, do: {:ok, :self_skip}

  def create(attrs) when is_map(attrs) do
    rid = attrs[:account_id]
    aid = attrs[:from_account_id]

    # Don't notify the recipient about an account they've blocked or muted.
    # (Mastodon's mute hides notifications by default.)
    if is_integer(rid) and is_integer(aid) and
         (Moderation.blocked?(rid, aid) or Moderation.muted?(rid, aid)) do
      {:ok, :blocked_skip}
    else
      %Notification{}
      |> Notification.changeset(attrs)
      |> Repo.insert(
        on_conflict: :nothing,
        conflict_target: [:account_id, :from_account_id, :type, :note_id]
      )
      |> tap_stream()
    end
  end

  # Push to the recipient's `user` stream — but only on a genuinely new
  # row. `on_conflict: :nothing` returns `id: nil` when the insert hit the
  # idempotency index, so a re-delivered favourite/follow doesn't re-fire.
  #
  # The doorbell hangs here too, behind the same guard: that idempotency
  # is already paid for, and it is exactly the idempotency a doorbell
  # needs — the same event must not buzz a pocket twice. Whether it may
  # buzz at all is `WebPush.deliverable?/3`'s call, not this line's.
  defp tap_stream({:ok, %Notification{id: id} = notif} = res) when not is_nil(id) do
    SukhiFedi.Streaming.publish_notification(notif.account_id, notif)
    SukhiFedi.Addons.WebPush.notify(notif)
    res
  end

  defp tap_stream(res), do: res

  @doc """
  Paged list. Returns notifications newest-first scoped to `viewer`,
  excluding dismissed rows.

  Opts:
    * `:max_id`, `:since_id`, `:min_id`, `:limit`
    * `:types`         — list of strings to keep
    * `:exclude_types` — list of strings to drop
  """
  @spec list(Account.t() | integer(), keyword() | map()) :: [Notification.t()]
  def list(%Account{id: id}, opts), do: list(id, opts)

  def list(account_id, opts) when is_integer(account_id) do
    opts = normalize(opts)

    Notification
    |> where([n], n.account_id == ^account_id and is_nil(n.dismissed_at))
    |> maybe_in(:type, opts[:types])
    |> maybe_not_in(:type, opts[:exclude_types])
    |> maybe_max_id(opts[:max_id])
    |> maybe_since_id(opts[:since_id])
    |> maybe_min_id(opts[:min_id])
    |> order_by([n], desc: n.id)
    |> limit(^clamp(opts[:limit] || @default_limit))
    |> Repo.all()
    |> Repo.preload([:from_account, note: [:account, :media, :tags]])
  end

  @doc "Scoped single fetch — won't return rows owned by other accounts."
  @spec get(Account.t() | integer(), integer() | String.t()) :: Notification.t() | nil
  def get(%Account{id: id}, notif_id), do: get(id, notif_id)

  def get(account_id, notif_id) when is_integer(account_id) do
    nid = SukhiFedi.Coercion.parse_id(notif_id)

    if is_nil(nid) do
      nil
    else
      Notification
      |> where([n], n.id == ^nid and n.account_id == ^account_id and is_nil(n.dismissed_at))
      |> Repo.one()
      |> case do
        nil -> nil
        n -> Repo.preload(n, [:from_account, note: [:account, :media, :tags]])
      end
    end
  end

  @doc "Bulk dismiss — Mastodon's `POST /clear` semantics."
  @spec clear(Account.t() | integer()) :: :ok
  def clear(%Account{id: id}), do: clear(id)

  def clear(account_id) when is_integer(account_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Notification
    |> where([n], n.account_id == ^account_id and is_nil(n.dismissed_at))
    |> Repo.update_all(set: [dismissed_at: now])

    :ok
  end

  @doc "Single-row dismiss — Mastodon's `POST /:id/dismiss`."
  @spec dismiss(Account.t() | integer(), integer() | String.t()) :: :ok
  def dismiss(%Account{id: id}, notif_id), do: dismiss(id, notif_id)

  def dismiss(account_id, notif_id) when is_integer(account_id) do
    nid = SukhiFedi.Coercion.parse_id(notif_id)
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    if nid do
      Notification
      |> where([n], n.id == ^nid and n.account_id == ^account_id and is_nil(n.dismissed_at))
      |> Repo.update_all(set: [dismissed_at: now])
    end

    :ok
  end

  # ── helpers ──────────────────────────────────────────────────────────────

  defp maybe_in(q, _field, nil), do: q
  defp maybe_in(q, _field, []), do: q
  defp maybe_in(q, field, list) when is_list(list), do: where(q, [n], field(n, ^field) in ^list)

  defp maybe_not_in(q, _field, nil), do: q
  defp maybe_not_in(q, _field, []), do: q

  defp maybe_not_in(q, field, list) when is_list(list),
    do: where(q, [n], field(n, ^field) not in ^list)

  defp maybe_max_id(q, nil), do: q
  defp maybe_max_id(q, v), do: where(q, [n], n.id < ^to_int(v))

  defp maybe_since_id(q, nil), do: q
  defp maybe_since_id(q, v), do: where(q, [n], n.id > ^to_int(v))

  defp maybe_min_id(q, nil), do: q
  defp maybe_min_id(q, v), do: where(q, [n], n.id > ^to_int(v))

  defp clamp(n) when is_integer(n) and n > 0 and n <= @max_limit, do: n
  defp clamp(_), do: @default_limit

  defp to_int(v), do: SukhiFedi.Coercion.to_int!(v)

  defp normalize(opts) when is_list(opts), do: Map.new(opts)
  defp normalize(opts) when is_map(opts), do: opts
end
