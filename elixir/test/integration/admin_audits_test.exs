# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Integration.AdminAuditsTest do
  use SukhiFedi.IntegrationCase, async: false

  @moduletag :integration

  import Ecto.Query

  alias SukhiFedi.AccountRepo
  alias SukhiFedi.Addons.Moderation
  alias SukhiFedi.Schema.{Account, AdminAudit}

  defp account!(u), do: insert_account!(%Account{username: u, display_name: u, summary: ""})

  test "an admin action writes an audit row in the same transaction" do
    admin = account!("aud_admin")
    target = account!("aud_target")

    assert {:ok, _} = Moderation.suspend_account(target.id, admin.id, "spam")

    audit =
      AccountRepo.one(
        from(a in AdminAudit,
          where: a.action == "account_suspended" and a.target_account_id == ^target.id
        )
      )

    assert audit
    assert audit.admin_account_id == admin.id
    assert audit.reason == "spam"
  end

  test "instance_blocked is audited with the domain and severity" do
    admin = account!("aud_admin_dom")

    assert {:ok, _} = Moderation.block_instance("evil.example", "suspend", "abuse", admin.id)

    audit = AccountRepo.one(from(a in AdminAudit, where: a.target_domain == "evil.example"))
    assert audit.action == "instance_blocked"
    assert audit.metadata["severity"] == "suspend"
  end

  test "audit rows cannot be deleted (append-only)" do
    row = AccountRepo.insert!(AdminAudit.changeset(%{action: "t_del", admin_account_id: 1}))
    assert_raise Postgrex.Error, ~r/keeps its rows/, fn -> AccountRepo.delete(row) end
  end

  test "audit rows cannot be updated (append-only)" do
    row = AccountRepo.insert!(AdminAudit.changeset(%{action: "t_upd", admin_account_id: 1}))

    assert_raise Postgrex.Error, ~r/keeps its rows/, fn ->
      row |> Ecto.Changeset.change(%{reason: "tampered"}) |> AccountRepo.update()
    end
  end
end
