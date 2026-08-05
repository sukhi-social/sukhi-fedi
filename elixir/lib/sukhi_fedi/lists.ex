# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Lists do
  @moduledoc """
  Lists / circles context.

  Lists are private to the owner: every read / write is scoped to a
  `viewer` account id. Membership is **independent of following** — a
  list is a roster (a "circle"), not a subscription, so any existing
  account can be added regardless of follow state. Following is a
  separate, explicit action; this module never touches `follows`
  (adding nor removing a member changes who you follow).

  An *exclusive* list's members are kept out of the owner's home
  timeline (see `excluded_account_ids/1` + `Timelines.home/2`); they
  surface only in the list's own feed. That is how you follow someone
  for the circle without their posts crowding home.

  All write helpers return either `{:ok, ...}` or `{:error,
  :not_found}`. `:not_found` covers both "no such list" and "list
  belongs to someone else" so we don't leak existence.
  """

  import Ecto.Query

  alias SukhiFedi.Repo
  alias SukhiFedi.Schema.{Account, List, Note}

  # ── lists CRUD ──────────────────────────────────────────────────────────

  @spec list_for(integer()) :: [List.t()]
  def list_for(viewer_id) when is_integer(viewer_id) do
    Repo.all(from l in List, where: l.account_id == ^viewer_id, order_by: [asc: l.id])
  end

  @spec get(integer(), integer() | String.t()) :: {:ok, List.t()} | {:error, :not_found}
  def get(viewer_id, id) do
    case SukhiFedi.Coercion.parse_id(id) do
      nil ->
        {:error, :not_found}

      n ->
        case Repo.get_by(List, id: n, account_id: viewer_id) do
          nil -> {:error, :not_found}
          %List{} = l -> {:ok, l}
        end
    end
  end

  @spec create(integer(), map()) :: {:ok, List.t()} | {:error, Ecto.Changeset.t()}
  def create(viewer_id, attrs) when is_integer(viewer_id) do
    attrs =
      attrs
      |> Map.new(fn {k, v} -> {to_string(k), v} end)
      |> Map.put("account_id", viewer_id)

    %List{}
    |> List.changeset(attrs)
    |> Repo.insert()
  end

  @spec update(integer(), integer() | String.t(), map()) ::
          {:ok, List.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def update(viewer_id, id, attrs) do
    with {:ok, list} <- get(viewer_id, id) do
      list
      |> List.changeset(stringify(attrs))
      |> Repo.update()
    end
  end

  @spec delete(integer(), integer() | String.t()) ::
          {:ok, List.t()} | {:error, :not_found}
  def delete(viewer_id, id) do
    with {:ok, list} <- get(viewer_id, id) do
      Repo.delete(list)
    end
  end

  # ── membership ──────────────────────────────────────────────────────────

  @spec list_accounts(integer(), integer() | String.t()) ::
          {:ok, [map()]} | {:error, :not_found}
  def list_accounts(viewer_id, id) do
    with {:ok, %List{id: lid}} <- get(viewer_id, id) do
      rows =
        Repo.all(
          from la in "list_accounts",
            join: a in SukhiFedi.Schema.Account,
            on: a.id == la.account_id,
            where: la.list_id == ^lid,
            select: %{
              id: a.id,
              username: a.username,
              display_name: a.display_name,
              summary: a.summary,
              domain: a.domain,
              actor_uri: a.actor_uri,
              avatar_url: a.avatar_url,
              banner_url: a.banner_url
            }
        )

      {:ok, rows}
    end
  end

  @doc """
  Add members to a circle. Membership is independent of following:
  any *existing* account may be added (a circle is a roster, not a
  subscription). Ids with no matching account are skipped — they'd
  violate the `list_accounts.account_id` FK otherwise. This never
  follows anyone; following stays a separate, explicit action.
  """
  @spec add_accounts(integer(), integer() | String.t(), [integer() | String.t()]) ::
          :ok | {:error, :not_found}
  def add_accounts(viewer_id, id, account_ids) do
    with {:ok, %List{id: lid}} <- get(viewer_id, id) do
      ids = Enum.map(account_ids, &SukhiFedi.Coercion.parse_id/1) |> Enum.reject(&is_nil/1)
      existing = Repo.all(from a in Account, where: a.id in ^ids, select: a.id)

      rows = Enum.map(existing, fn aid -> %{list_id: lid, account_id: aid} end)

      Repo.insert_all("list_accounts", rows,
        on_conflict: :nothing,
        conflict_target: [:list_id, :account_id]
      )

      :ok
    end
  end

  @spec remove_accounts(integer(), integer() | String.t(), [integer() | String.t()]) ::
          :ok | {:error, :not_found}
  def remove_accounts(viewer_id, id, account_ids) do
    with {:ok, %List{id: lid}} <- get(viewer_id, id) do
      ids = Enum.map(account_ids, &SukhiFedi.Coercion.parse_id/1) |> Enum.reject(&is_nil/1)

      Repo.delete_all(
        from la in "list_accounts",
          where: la.list_id == ^lid and la.account_id in ^ids
      )

      :ok
    end
  end

  # ── timeline ────────────────────────────────────────────────────────────

  @doc """
  List timeline: newest-first notes from list members (public,
  unlisted, followers). Same paging shape as the home timeline.
  """
  @spec timeline(integer(), integer() | String.t(), keyword() | map()) ::
          {:ok, [Note.t()]} | {:error, :not_found}
  def timeline(viewer_id, id, opts \\ []) do
    with {:ok, %List{id: lid}} <- get(viewer_id, id) do
      opts = if is_map(opts), do: opts, else: Map.new(opts)
      limit = clamp(opts[:limit])

      base =
        from n in Note,
          join: la in "list_accounts",
          on: la.account_id == n.account_id,
          where: la.list_id == ^lid and n.visibility in ^SukhiFedi.Visibility.not_direct()

      results =
        base
        |> maybe_only_media(opts[:only_media])
        |> maybe_hide_sensitive(opts[:hide_sensitive])
        |> maybe_max_id(opts[:max_id])
        |> maybe_since_id(opts[:since_id])
        |> maybe_min_id(opts[:min_id])
        |> order_by([n], desc: n.id)
        |> limit(^limit)
        |> Repo.all()
        |> Repo.preload([:account, :media, :tags])

      {:ok, results}
    end
  end

  @doc """
  Account ids whose posts are kept out of the owner's home timeline:
  members of any *exclusive* circle the viewer owns. The viewer's own
  id is never included, so home can subtract this set freely. See
  `Timelines.home/2`.
  """
  @spec excluded_account_ids(integer()) :: [integer()]
  def excluded_account_ids(viewer_id) when is_integer(viewer_id) do
    Repo.all(
      from la in "list_accounts",
        join: l in List,
        on: l.id == la.list_id,
        where: l.account_id == ^viewer_id and l.exclusive == true,
        where: la.account_id != ^viewer_id,
        select: la.account_id,
        distinct: true
    )
  end

  @doc """
  Members whose home-timeline posts should be *filtered*, grouped by the
  gate condition their list carries. Only *non-exclusive* lists contribute
  (exclusive ones drop members from home outright). The keyword gate is
  applied directly in SQL by `Timelines.home/2` (it varies per list), so it
  isn't returned here. Used by `Timelines.home/2`.
  """
  @spec home_filter_members(integer()) :: %{
          only_media: [integer()],
          hide_boosts: [integer()],
          hide_sensitive: [integer()],
          hide_replies: [integer()],
          replies_to_me: [integer()]
        }
  def home_filter_members(viewer_id) when is_integer(viewer_id) do
    rows =
      Repo.all(
        from la in "list_accounts",
          join: l in List,
          on: l.id == la.list_id,
          where:
            l.account_id == ^viewer_id and l.exclusive == false and
              (l.filter_only_media or l.filter_hide_boosts or l.filter_hide_sensitive or
                 l.filter_replies != "all"),
          select:
            {la.account_id, l.filter_only_media, l.filter_hide_boosts, l.filter_hide_sensitive,
             l.filter_replies}
      )

    %{
      only_media: for({id, true, _, _, _} <- rows, do: id) |> Enum.uniq(),
      hide_boosts: for({id, _, true, _, _} <- rows, do: id) |> Enum.uniq(),
      hide_sensitive: for({id, _, _, true, _} <- rows, do: id) |> Enum.uniq(),
      hide_replies: for({id, _, _, _, "hide"} <- rows, do: id) |> Enum.uniq(),
      replies_to_me: for({id, _, _, _, "to_me"} <- rows, do: id) |> Enum.uniq()
    }
  end

  # ── helpers ─────────────────────────────────────────────────────────────

  defp stringify(attrs) when is_map(attrs) do
    Map.new(attrs, fn {k, v} -> {to_string(k), v} end)
  end

  defp clamp(n) when is_integer(n) and n > 0 and n <= 40, do: n
  defp clamp(_), do: 20

  # 表示フィルタ(timelines.ex と同じ判定)。メディア付きだけ / sensitive・CW を隠す。
  defp maybe_only_media(q, true),
    do: where(q, [n], fragment("EXISTS (SELECT 1 FROM note_media nm WHERE nm.note_id = ?)", n.id))

  defp maybe_only_media(q, _), do: q

  defp maybe_hide_sensitive(q, true),
    do: where(q, [n], n.sensitive == false and is_nil(n.cw))

  defp maybe_hide_sensitive(q, _), do: q

  defp maybe_max_id(q, nil), do: q
  defp maybe_max_id(q, v), do: where(q, [n], n.id < ^to_int(v))

  defp maybe_since_id(q, nil), do: q
  defp maybe_since_id(q, v), do: where(q, [n], n.id > ^to_int(v))

  defp maybe_min_id(q, nil), do: q
  defp maybe_min_id(q, v), do: where(q, [n], n.id > ^to_int(v))

  defp to_int(v), do: SukhiFedi.Coercion.to_int!(v)
end
