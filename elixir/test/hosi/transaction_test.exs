# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Hosi.TransactionTest do
  use SukhiFedi.HosiCase
  import Ecto.Query

  alias Ecto.Multi
  alias SukhiFedi.Schema.Account

  test "Repo.transaction commits, and rolls back what it wrote" do
    assert {:ok, %Account{}} = Repo.transaction(fn -> account!("kept") end)
    assert {:error, :nope} = Repo.transaction(fn -> account!("undone") && Repo.rollback(:nope) end)
    assert Repo.all(from(a in Account, select: a.username)) == ["kept"]
  end

  test "Multi aborts and undoes on a failing step" do
    multi =
      Multi.new()
      |> Multi.insert(:a, %Account{username: "m1"})
      |> Multi.run(:fail, fn _, _ -> {:error, :bad} end)

    assert {:error, :fail, :bad, _} = Repo.transaction(multi)
    assert Repo.aggregate(Account, :count) == 0
  end

  test "update_all and delete_all, and an upsert" do
    account!("a")
    account!("b")
    assert {2, nil} = Repo.update_all(Account, set: [display_name: "x"])
    assert {1, nil} = Repo.delete_all(from(a in Account, where: a.username == "a"))

    assert {:ok, _} =
             Repo.insert(%Account{username: "b", display_name: "y"},
               on_conflict: {:replace, [:display_name]},
               conflict_target: [:username]
             )

    assert [%{username: "b", display_name: "y"}] = Repo.all(Account)
  end

  test "a Multi of known changesets is one atomic write" do
    a = account!("a")

    multi =
      Multi.new()
      |> Multi.insert(:b, Ecto.Changeset.change(%Account{}, username: "b"))
      |> Multi.update(:a, Ecto.Changeset.change(a, display_name: "A"))

    assert {:ok, %{b: %Account{}, a: %Account{display_name: "A"}}} = Repo.transaction(multi)
    refute Repo.in_transaction?()
    assert Repo.aggregate(Account, :count) == 2
  end
end
