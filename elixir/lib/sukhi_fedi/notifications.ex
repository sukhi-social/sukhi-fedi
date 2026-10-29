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

  ## Pace

  A person may slow the *ambient* notifications (everything but
  `WebPush.direct_types/0`: favourites, boosts, follows…): hold each for
  `accounts.notification_hold_minutes` before it shows, and, with
  `accounts.notification_grouping`, fold same-kind rows into one. Direct ones
  (mentions, follow requests) are never held or folded.

  A client may ask for more than the account chose — `hold_minutes:` and
  `grouping:` in the opts of every read and dismiss — and only ever for more:
  the effective hold is the larger of the two, grouping is on if either is.
  That is how a client with a house pace (web-unpoly) slows everyone it
  serves without touching anyone's setting.

  The whole rule is `pace/2` (what applies) and `scope/3` (what a
  read or a dismiss may touch). Every read path goes through `scope/2`, so a
  held row is invisible to the list, the single fetch, `clear` and `dismiss`
  alike. A held row is not streamed when it is written; it shows at the next
  read after its hour. The row itself is always stored in full.
  """

  import Ecto.Query

  alias SukhiFedi.Repo
  alias SukhiFedi.Addons.Moderation
  alias SukhiFedi.Addons.WebPush
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
    unless held_on_arrival?(notif), do: SukhiFedi.Streaming.publish_notification(notif.account_id, notif)
    WebPush.notify(notif)
    res
  end

  defp tap_stream(res), do: res

  # ── pace ─────────────────────────────────────────────────────────────────

  @doc """
  What the account chose for ambient notifications:
  `%{hold_minutes: non_neg_integer(), grouping: boolean()}`. Never chosen
  (NULL) and unknown accounts are `0` / `false`: nothing is held.
  """
  @spec pace(integer(), keyword() | map()) :: %{hold_minutes: non_neg_integer(), grouping: boolean()}
  def pace(account_id, ask \\ []) when is_integer(account_id) do
    ask = normalize(ask)

    from(a in Account,
      where: a.id == ^account_id,
      select: {a.notification_hold_minutes, a.notification_grouping}
    )
    |> Repo.one()
    |> case do
      {hold, grouping} -> %{hold_minutes: hold || 0, grouping: grouping == true}
      nil -> %{hold_minutes: 0, grouping: false}
    end
    |> then(fn mine ->
      %{
        hold_minutes: max(mine.hold_minutes, clamp_hold(ask[:hold_minutes])),
        grouping: mine.grouping or ask[:grouping] == true
      }
    end)
  end

  defp clamp_hold(n) when is_integer(n) and n > 0, do: min(n, 1440)
  defp clamp_hold(_), do: 0

  # The one place that decides what the account may see (and so touch).
  # `now` is passed in so a caller reading twice agrees with itself.
  defp scope(account_id, %{hold_minutes: hold}, now) do
    base = where(Notification, [n], n.account_id == ^account_id and is_nil(n.dismissed_at))

    if hold > 0 do
      cutoff = DateTime.add(now, -hold * 60, :second)
      direct = WebPush.direct_types()
      where(base, [n], n.type in ^direct or n.created_at <= ^cutoff)
    else
      base
    end
  end

  defp held_on_arrival?(%Notification{type: type, account_id: id}) do
    type not in WebPush.direct_types() and pace(id).hold_minutes > 0
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  @doc """
  Paged list. Returns notifications newest-first scoped to `viewer`,
  excluding dismissed rows and, per the viewer's pace, held ones.

  Opts:
    * `:max_id`, `:since_id`, `:min_id`, `:limit`
    * `:types`         — list of strings to keep
    * `:exclude_types` — list of strings to drop

  With grouping on, ambient rows of one kind in the page come back as one
  row: the newest, with `group` = every member's `from_account` (newest
  first) and `cursor_id` = the oldest member's id, which is the id a client
  pages from (the API puts it in `Link`). A group does not span pages.
  """
  @spec list(Account.t() | integer(), keyword() | map()) :: [Notification.t()]
  def list(%Account{id: id}, opts), do: list(id, opts)

  def list(account_id, opts) when is_integer(account_id) do
    opts = normalize(opts)
    pace = pace(account_id, opts)

    account_id
    |> scope(pace, now())
    |> maybe_in(:type, opts[:types])
    |> maybe_not_in(:type, opts[:exclude_types])
    |> maybe_max_id(opts[:max_id])
    |> maybe_since_id(opts[:since_id])
    |> maybe_min_id(opts[:min_id])
    |> order_by([n], desc: n.id)
    |> limit(^clamp(opts[:limit] || @default_limit))
    |> Repo.all()
    |> Repo.preload([:from_account, note: [:account, :media, :tags]])
    |> group(pace.grouping)
  end

  # Newest-first rows in, newest-first out: a group sits where its newest
  # member was. Direct rows are never folded.
  defp group(rows, false), do: rows

  defp group(rows, true) do
    direct = WebPush.direct_types()

    keyed =
      Enum.map(rows, fn n ->
        if n.type in direct, do: {{:single, n.id}, n}, else: {{n.type, n.note_id}, n}
      end)

    members = keyed |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))

    keyed
    |> Enum.uniq_by(&elem(&1, 0))
    |> Enum.map(fn {key, n} ->
      all = Map.fetch!(members, key)

      case all do
        [_one] -> n
        _ -> %{n | group: Enum.map(all, & &1.from_account), cursor_id: all |> List.last() |> Map.fetch!(:id)}
      end
    end)
  end

  @doc "Scoped single fetch — won't return rows owned by other accounts."
  @spec get(Account.t() | integer(), integer() | String.t(), keyword() | map()) ::
          Notification.t() | nil
  def get(account, notif_id, ask \\ [])
  def get(%Account{id: id}, notif_id, ask), do: get(id, notif_id, ask)

  def get(account_id, notif_id, ask) when is_integer(account_id) do
    nid = SukhiFedi.Coercion.parse_id(notif_id)

    if is_nil(nid) do
      nil
    else
      account_id
      |> scope(pace(account_id, ask), now())
      |> where([n], n.id == ^nid)
      |> Repo.one()
      |> case do
        nil -> nil
        n -> Repo.preload(n, [:from_account, note: [:account, :media, :tags]])
      end
    end
  end

  @doc "Bulk dismiss — Mastodon's `POST /clear` semantics. Held rows are not yet seen, so not cleared."
  @spec clear(Account.t() | integer()) :: :ok
  def clear(account, ask \\ [])
  def clear(%Account{id: id}, ask), do: clear(id, ask)

  def clear(account_id, ask) when is_integer(account_id) do
    now = now()

    account_id
    |> scope(pace(account_id, ask), now)
    |> Repo.update_all(set: [dismissed_at: now])

    :ok
  end

  @doc "Single-row dismiss — Mastodon's `POST /:id/dismiss`."
  @spec dismiss(Account.t() | integer(), integer() | String.t()) :: :ok
  def dismiss(account, notif_id, ask \\ [])
  def dismiss(%Account{id: id}, notif_id, ask), do: dismiss(id, notif_id, ask)

  def dismiss(account_id, notif_id, ask) when is_integer(account_id) do
    nid = SukhiFedi.Coercion.parse_id(notif_id)
    now = now()

    if nid do
      account_id
      |> scope(pace(account_id, ask), now)
      |> where([n], n.id == ^nid)
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
