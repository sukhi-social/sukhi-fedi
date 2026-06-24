# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Announcements do
  @moduledoc """
  Server announcements context.

  An announcement is a note the admin pins for the people on this box.
  It is local only — never federated — and surfaces through Mastodon's
  `/api/v1/announcements`. Two audiences read from here:

    * **readers** — `active_for/1` returns the announcements a logged-in
      account should see right now (published, inside their optional
      time window), each tagged with whether that reader has dismissed
      it; `dismiss/2` records "I've seen this".

    * **the admin** — `list_all/0`, `create/1`, `update/2`, `delete/1`
      manage the set, drafts included. Authoring is admin-gated one
      layer up (`SukhiApi.Capabilities.Admin`); this module trusts its
      caller, the same way `Lists` trusts the viewer id handed to it.

  Publishing is a flag, not a separate verb: set `published: true` and,
  if no `published_at` was given, we stamp it now so the reader-facing
  `published_at` is honest.
  """

  import Ecto.Query

  alias SukhiFedi.Repo
  alias SukhiFedi.Schema.{Announcement, AnnouncementDismissal}

  # ── readers ───────────────────────────────────────────────────────────────

  @doc """
  Active announcements for a reader, newest first, each as
  `{announcement, read?}` where `read?` is whether the reader dismissed
  it. "Active" = published and inside its optional `starts_at`..`ends_at`
  window.
  """
  @spec active_for(integer()) :: [{Announcement.t(), boolean()}]
  def active_for(viewer_id) when is_integer(viewer_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    announcements =
      Repo.all(
        from a in Announcement,
          where: a.published == true,
          where: is_nil(a.starts_at) or a.starts_at <= ^now,
          where: is_nil(a.ends_at) or a.ends_at >= ^now,
          order_by: [desc: a.published_at, desc: a.id]
      )

    dismissed = dismissed_ids(viewer_id, Enum.map(announcements, & &1.id))
    Enum.map(announcements, fn a -> {a, MapSet.member?(dismissed, a.id)} end)
  end

  defp dismissed_ids(_viewer_id, []), do: MapSet.new()

  defp dismissed_ids(viewer_id, ids) do
    Repo.all(
      from d in AnnouncementDismissal,
        where: d.account_id == ^viewer_id and d.announcement_id in ^ids,
        select: d.announcement_id
    )
    |> MapSet.new()
  end

  @doc """
  Mark an announcement read for one reader. Idempotent — dismissing
  twice is fine (the unique index makes the second a no-op). Returns
  `{:error, :not_found}` for an announcement that isn't active, so a
  reader can't probe drafts.
  """
  @spec dismiss(integer(), integer() | String.t()) :: :ok | {:error, :not_found}
  def dismiss(viewer_id, id) when is_integer(viewer_id) do
    with {:ok, ann} <- fetch_active(viewer_id, id) do
      %AnnouncementDismissal{}
      |> AnnouncementDismissal.changeset(%{announcement_id: ann.id, account_id: viewer_id})
      |> Repo.insert(on_conflict: :nothing, conflict_target: [:announcement_id, :account_id])

      :ok
    end
  end

  defp fetch_active(viewer_id, id) do
    case SukhiFedi.Coercion.parse_id(id) do
      nil ->
        {:error, :not_found}

      n ->
        active_for(viewer_id)
        |> Enum.find(fn {a, _read} -> a.id == n end)
        |> case do
          {a, _read} -> {:ok, a}
          nil -> {:error, :not_found}
        end
    end
  end

  # ── admin ─────────────────────────────────────────────────────────────────

  @spec list_all() :: [Announcement.t()]
  def list_all do
    Repo.all(from a in Announcement, order_by: [desc: a.id])
  end

  @spec get(integer() | String.t()) :: {:ok, Announcement.t()} | {:error, :not_found}
  def get(id) do
    case SukhiFedi.Coercion.parse_id(id) do
      nil -> {:error, :not_found}
      n -> Repo.get(Announcement, n) |> wrap()
    end
  end

  @spec create(map()) :: {:ok, Announcement.t()} | {:error, Ecto.Changeset.t()}
  def create(attrs) do
    %Announcement{}
    |> Announcement.changeset(stamp_published(stringify(attrs)))
    |> Repo.insert()
  end

  @spec update(integer() | String.t(), map()) ::
          {:ok, Announcement.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def update(id, attrs) do
    with {:ok, ann} <- get(id) do
      ann
      |> Announcement.changeset(stamp_published(stringify(attrs), ann))
      |> Repo.update()
    end
  end

  @spec delete(integer() | String.t()) :: {:ok, Announcement.t()} | {:error, :not_found}
  def delete(id) do
    with {:ok, ann} <- get(id) do
      Repo.delete(ann)
    end
  end

  # When an announcement turns published and carries no `published_at`,
  # stamp it now so the reader-facing timestamp is real. We never clear
  # it on unpublish — a re-publish keeps the original "first published"
  # instant unless the admin sets a new one.
  defp stamp_published(attrs, existing \\ %Announcement{}) do
    becoming_published? = attrs["published"] in [true, "true", "1"]
    already_stamped? = not is_nil(existing.published_at) or not is_nil(attrs["published_at"])

    if becoming_published? and not already_stamped? do
      Map.put(attrs, "published_at", DateTime.utc_now() |> DateTime.truncate(:second))
    else
      attrs
    end
  end

  defp stringify(attrs), do: Map.new(attrs, fn {k, v} -> {to_string(k), v} end)

  defp wrap(nil), do: {:error, :not_found}
  defp wrap(%Announcement{} = a), do: {:ok, a}
end
