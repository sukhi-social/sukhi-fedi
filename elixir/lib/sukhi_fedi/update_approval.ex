# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.UpdateApproval do
  @moduledoc """
  The admin's "apply it now" (docs/OPS_UPDATE_PROPOSAL.ja.md §3). Writes
  `approve.json` for `sukhi-gitops-sync --apply --approved` on the box.

  Approval widens nothing: the box re-verifies signature, images and
  preflight, and only then checks that `commit` is the verified target and
  the file is under an hour old. All this module decides is *when*.

  Only an `:update_available` status (fresh, verified) can be approved, and
  the commit must be the one the admin was shown — a newer version arriving
  between page load and click is refused, not silently swapped in.

  Order: audit row first, then the file. A failed write leaves an audit row
  with no effect; the reverse would be an unaudited update.
  """

  alias SukhiFedi.{Repo, UpdateStatus}
  alias SukhiFedi.Schema.AdminAudit

  @default_dir "/run/sukhi-approve"

  def dir, do: Application.get_env(:sukhi_fedi, :gitops_approve_dir) || @default_dir

  @spec approve(map(), String.t(), DateTime.t()) ::
          :ok | {:error, :no_update | :changed | :bad_commit | :bad_admin | :write_failed}
  def approve(admin, commit, now \\ DateTime.utc_now()) do
    with true <- is_binary(commit) and commit =~ ~r/\A\h{40}\z/ || {:error, :bad_commit},
         true <- admin.username =~ ~r/\A[\w.+-]{1,100}\z/ || {:error, :bad_admin},
         %{state: :update_available, available: %{"commit" => avail}} <-
           UpdateStatus.read(now) || {:error, :no_update},
         true <- avail == commit || {:error, :changed},
         {:ok, _} <- audit(admin, commit) |> audit_result(),
         :ok <- write(commit, admin.username, now) do
      :ok
    else
      {:error, _} = err -> err
      %{} -> {:error, :no_update}
    end
  end

  defp audit_result({:ok, _} = ok), do: ok
  defp audit_result(_), do: {:error, :write_failed}

  defp audit(admin, commit) do
    %{action: "update_approve", admin_account_id: admin.id, metadata: %{commit: commit}}
    |> AdminAudit.changeset()
    |> Repo.insert()
  end

  # tmp → rename: the box's path unit fires on a complete file only.
  defp write(commit, by, now) do
    final = Path.join(dir(), "approve.json")
    tmp = Path.join(dir(), ".approve.json.#{System.unique_integer([:positive])}")
    body = Jason.encode!(%{commit: commit, by: by, at: DateTime.to_iso8601(now)})

    with :ok <- File.write(tmp, body),
         :ok <- File.rename(tmp, final) do
      :ok
    else
      _ ->
        File.rm(tmp)
        {:error, :write_failed}
    end
  end
end
