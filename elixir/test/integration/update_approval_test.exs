# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Integration.UpdateApprovalTest do
  use SukhiFedi.IntegrationCase, async: false

  @moduletag :integration

  import Ecto.Query

  alias SukhiFedi.{UpdateApproval, UpdateStatus}
  alias SukhiFedi.Schema.{Account, AdminAudit}

  @commit String.duplicate("b", 40)

  setup do
    base = Path.join(System.tmp_dir!(), "approval-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(base, "approve"))
    status = Path.join(base, "status.json")

    prev =
      for k <- [:gitops_status_path, :gitops_approve_dir],
          do: {k, Application.get_env(:sukhi_fedi, k)}

    Application.put_env(:sukhi_fedi, :gitops_status_path, status)
    Application.put_env(:sukhi_fedi, :gitops_approve_dir, Path.join(base, "approve"))

    on_exit(fn ->
      File.rm_rf(base)
      for {k, v} <- prev, do: Application.put_env(:sukhi_fedi, k, v)
    end)

    admin = Repo.insert!(%Account{username: "upd_admin", display_name: "a", summary: ""})
    %{admin: admin, status: status, approve: Path.join([base, "approve", "approve.json"])}
  end

  defp write_status(path, overrides \\ %{}) do
    doc =
      Map.merge(
        %{
          "schema" => 1,
          "env" => "dev",
          "checked_at" => DateTime.to_iso8601(DateTime.utc_now()),
          "state" => "update_available",
          "available" => %{"commit" => @commit, "version" => "sha-3f9e0a1", "verified" => true}
        },
        overrides
      )

    File.write!(path, Jason.encode!(doc))
  end

  defp audits(admin),
    do:
      Repo.all(
        from(a in AdminAudit,
          where: a.action == "update_approve" and a.admin_account_id == ^admin.id
        )
      )

  test "approves the shown commit: audit row, then approve.json", %{
    admin: admin,
    status: st,
    approve: file
  } do
    write_status(st)
    assert :ok = UpdateApproval.approve(admin, @commit)

    doc = file |> File.read!() |> Jason.decode!()
    assert doc["commit"] == @commit
    assert doc["by"] == "upd_admin"
    assert {:ok, _, _} = DateTime.from_iso8601(doc["at"])
    assert [%{metadata: %{"commit" => @commit}}] = audits(admin)
    # no half-written temp file is left beside it
    assert Path.wildcard(Path.join(Path.dirname(file), ".approve.json.*")) == []
  end

  test "a version that changed after the page loaded is refused", %{
    admin: admin,
    status: st,
    approve: file
  } do
    write_status(st)
    assert {:error, :changed} = UpdateApproval.approve(admin, String.duplicate("c", 40))
    refute File.exists?(file)
    assert audits(admin) == []
  end

  test "only :update_available can be approved", %{admin: admin, status: st, approve: file} do
    for state <- ["up_to_date", "rejected", "error"] do
      write_status(st, %{"state" => state})
      assert {:error, :no_update} = UpdateApproval.approve(admin, @commit)
    end

    File.rm!(st)
    assert {:error, :no_update} = UpdateApproval.approve(admin, @commit)
    refute File.exists?(file)
  end

  test "a stale status cannot be approved", %{admin: admin, status: st} do
    write_status(st, %{"checked_at" => "2020-01-01T00:00:00Z"})
    assert UpdateStatus.read().state == :stale
    assert {:error, :no_update} = UpdateApproval.approve(admin, @commit)
  end

  test "a malformed commit never reaches the file", %{admin: admin, status: st, approve: file} do
    write_status(st)
    assert {:error, :bad_commit} = UpdateApproval.approve(admin, "../../etc")
    assert {:error, :bad_commit} = UpdateApproval.approve(admin, nil)
    refute File.exists?(file)
  end

  test "an unwritable directory is reported, and the audit row stays", %{admin: admin, status: st} do
    write_status(st)
    Application.put_env(:sukhi_fedi, :gitops_approve_dir, "/nonexistent/sukhi-approve")
    assert {:error, :write_failed} = UpdateApproval.approve(admin, @commit)
    assert [_] = audits(admin)
  end
end
