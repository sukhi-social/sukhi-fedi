# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Hosi.TransactionTest do
  use SukhiFedi.HosiCase
  import Ecto.Query

  alias Ecto.Multi
  alias SukhiFedi.Schema.InstanceBlock

  test "Repo.transaction commits, and rolls back what it wrote" do
    assert {:ok, %InstanceBlock{}} = Repo.transaction(fn -> block!("kept") end)
    assert {:error, :nope} = Repo.transaction(fn -> block!("undone") && Repo.rollback(:nope) end)
    assert Repo.all(from(a in InstanceBlock, select: a.domain)) == ["kept"]
  end

  test "Multi aborts and undoes on a failing step" do
    multi =
      Multi.new()
      |> Multi.insert(:a, %InstanceBlock{domain: "m1"})
      |> Multi.run(:fail, fn _, _ -> {:error, :bad} end)

    assert {:error, :fail, :bad, _} = Repo.transaction(multi)
    assert Repo.aggregate(InstanceBlock, :count) == 0
  end

  test "update_all and delete_all, and an upsert" do
    block!("a")
    block!("b")
    assert {2, nil} = Repo.update_all(InstanceBlock, set: [reason: "x"])
    assert {1, nil} = Repo.delete_all(from(a in InstanceBlock, where: a.domain == "a"))

    assert {:ok, _} =
             Repo.insert(%InstanceBlock{domain: "b", reason: "y"},
               on_conflict: {:replace, [:reason]},
               conflict_target: [:domain]
             )

    assert [%{domain: "b", reason: "y"}] = Repo.all(InstanceBlock)
  end

  test "a Multi of known changesets is one atomic write" do
    a = block!("a")

    multi =
      Multi.new()
      |> Multi.insert(:b, Ecto.Changeset.change(%InstanceBlock{}, domain: "b"))
      |> Multi.update(:a, Ecto.Changeset.change(a, reason: "A"))

    assert {:ok, %{b: %InstanceBlock{}, a: %InstanceBlock{reason: "A"}}} = Repo.transaction(multi)
    refute Repo.in_transaction?()
    assert Repo.aggregate(InstanceBlock, :count) == 2
  end

  defp block!(domain), do: Repo.insert!(%InstanceBlock{domain: domain})
end
