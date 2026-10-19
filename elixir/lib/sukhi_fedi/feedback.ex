# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Feedback do
  @moduledoc """
  The feedback inbox (docs/FEEDBACK.md).

  Writing is open (anonymous allowed); reading is the operator's, gated
  one layer up by `SukhiApi.AdminAuth` + the `admin:*` scope, the same
  way `Announcements` trusts its caller. Validation lives in
  `Schema.FeedbackItem.changeset/2` and nowhere else; the rate limit
  lives at the gateway route.
  """

  import Ecto.Query

  alias SukhiFedi.Coercion
  alias SukhiFedi.Repo
  alias SukhiFedi.Schema.FeedbackItem

  @doc "Store one item. `account_id` is the verified sender, or `nil`."
  @spec submit(map(), integer() | nil) :: {:ok, FeedbackItem.t()} | {:error, Ecto.Changeset.t()}
  def submit(attrs, account_id) when is_map(attrs) do
    attrs |> FeedbackItem.changeset(account_id) |> Repo.insert()
  end

  @doc """
  A page, newest first, with the total. `handled`: `true`, `false`, or
  `nil` for both.
  """
  @spec list(%{offset: non_neg_integer(), limit: pos_integer()}, boolean() | nil) ::
          {[FeedbackItem.t()], non_neg_integer()}
  def list(%{offset: offset, limit: limit}, handled \\ nil) do
    base = filter(FeedbackItem, handled)

    items = Repo.all(from f in base, order_by: [desc: f.id], offset: ^offset, limit: ^limit)

    {items, Repo.aggregate(base, :count, :id)}
  end

  defp filter(q, nil), do: q
  defp filter(q, true), do: from(f in q, where: not is_nil(f.handled_at))
  defp filter(q, false), do: from(f in q, where: is_nil(f.handled_at))

  @doc "Mark one item handled by `admin_id`. Idempotent."
  @spec mark_handled(integer() | String.t(), integer()) ::
          {:ok, FeedbackItem.t()} | {:error, :not_found}
  def mark_handled(id, admin_id) when is_integer(admin_id) do
    case Coercion.parse_id(id) do
      nil -> {:error, :not_found}
      n -> FeedbackItem |> Repo.get(n) |> do_mark(admin_id)
    end
  end

  defp do_mark(nil, _admin_id), do: {:error, :not_found}
  defp do_mark(%FeedbackItem{handled_at: %DateTime{}} = item, _admin_id), do: {:ok, item}

  defp do_mark(%FeedbackItem{} = item, admin_id) do
    item |> FeedbackItem.handled_changeset(admin_id) |> Repo.update()
  end

  @doc """
  Retention: delete *handled* items handled before `cutoff`. Unhandled
  items are never purged. Operator-invoked (not scheduled); returns the
  number deleted.
  """
  @spec purge_handled_before(DateTime.t()) :: non_neg_integer()
  def purge_handled_before(%DateTime{} = cutoff) do
    {n, _} = Repo.delete_all(from f in FeedbackItem, where: f.handled_at < ^cutoff)
    n
  end
end
