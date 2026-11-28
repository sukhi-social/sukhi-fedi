# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Fedi.DeliverySuspension.Admin do
  @moduledoc """
  What an admin may do about the rests other servers have asked of us
  (FEP-f799, docs/DELIVERY_SUSPENSION.md): choose, on this server only, to
  **ignore** one, and to stop ignoring it.

  Ignoring changes nothing in the peer's record. The notice stays in the store
  exactly as received; its `id` is added to `suspension_ignores`, and the
  cache (the one place the delivery worker asks) leaves it out. So deliveries
  to that target go out as usual at once, a later revision of the same notice
  stays ignored, and a new rest from the peer is a new `id` and is judged on
  its own. Un-ignoring puts it back for as long as it still has to run.

  Each choice is written to the admin audit trail (`suspension_ignored` /
  `suspension_unignored`) and announced to telemetry
  (`[:sukhi_fedi, :delivery_suspension, :ignored]`).
  """

  alias SukhiFedi.AccountRepo
  alias SukhiFedi.Fedi.DeliverySuspension.{Store, Upkeep}
  alias SukhiFedi.Schema.AdminAudit

  @doc "Ignore the notice `id` (the admin is `admin_id`, for the audit trail)."
  @spec ignore(String.t(), integer() | nil) :: :ok | {:error, :not_found | term()}
  def ignore(id, admin_id \\ nil), do: choose(:ignore, id, admin_id)

  @doc "Stop ignoring the notice `id`."
  @spec unignore(String.t(), integer() | nil) :: :ok | {:error, :not_found | term()}
  def unignore(id, admin_id \\ nil), do: choose(:unignore, id, admin_id)

  defp choose(action, id, admin_id) when is_binary(id) do
    with {:ok, notice, _create_id} <- known(id),
         :ok <- write(action, id),
         :ok <- Upkeep.reload() do
      audit(action, notice, admin_id)

      :telemetry.execute(
        [:sukhi_fedi, :delivery_suspension, :ignored],
        %{count: 1},
        %{action: action}
      )

      :ok
    end
  end

  defp choose(_action, _id, _admin_id), do: {:error, :not_found}

  defp known(id) do
    case Store.get_notice(id) do
      {:ok, _notice, _create_id} = found -> found
      :none -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  defp write(:ignore, id), do: Store.ignore(id, DateTime.utc_now())
  defp write(:unignore, id), do: Store.unignore(id)

  defp audit(action, notice, admin_id) do
    AccountRepo.insert(
      AdminAudit.changeset(%{
        action: "suspension_#{action}d",
        admin_account_id: admin_id,
        target_domain: host(notice.target),
        metadata: %{"notice_id" => notice.id, "controller" => notice.controller}
      })
    )

    :ok
  rescue
    # The choice has been made; a trail that cannot be written is not a reason to undo it.
    _ -> :ok
  end

  defp host(target) do
    case URI.parse(target) do
      %URI{host: host} when is_binary(host) -> host
      _ -> nil
    end
  end
end
