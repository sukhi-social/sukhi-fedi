# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Hosi.SmallModulesTest do
  use SukhiFedi.HosiCase

  alias SukhiFedi.{FollowInvites, Markers, NoteDrafts}

  describe "Markers" do
    test "upsert creates, then bumps the version; get reads by timeline" do
      a = account!()
      assert {:ok, %{version: 1, last_read_id: "10"}} = Markers.upsert(a.id, "home", "10")
      assert {:ok, %{version: 2, last_read_id: "11"}} = Markers.upsert(a.id, "home", "11")
      assert {:ok, _} = Markers.upsert(a.id, "notifications", "5")

      got = Markers.get(a.id, ["home", "notifications", "bogus"])
      assert Map.keys(got) |> Enum.sort() == ["home", "notifications"]
      assert got["home"].last_read_id == "11"
    end

    test "another account's markers are not read" do
      a = account!("a")
      b = account!("b")
      {:ok, _} = Markers.upsert(a.id, "home", "1")
      assert Markers.get(b.id, ["home"]) == %{}
    end
  end

  describe "FollowInvites" do
    test "mint, list newest first, invited?, revoke" do
      a = account!()
      {:ok, one} = FollowInvites.mint(a.id)
      {:ok, two} = FollowInvites.mint(a.id)

      assert [%{id: id1}, %{id: id2}] = FollowInvites.list(a.id)
      assert Enum.sort([id1, id2]) == Enum.sort([one.id, two.id])

      url = "https://example.test/users/ada/invites/#{one.code}"
      assert FollowInvites.invited?(a.id, url)
      refute FollowInvites.invited?(a.id, "https://example.test/users/ada/invites/nope")

      assert {:ok, _} = FollowInvites.revoke(a.id, one.code)
      refute FollowInvites.invited?(a.id, url)
      assert {:error, :not_found} = FollowInvites.revoke(a.id, one.code)
    end
  end

  describe "NoteDrafts" do
    test "one draft per account: upsert replaces, delete is idempotent" do
      a = account!()
      assert NoteDrafts.get(a) == nil

      assert {:ok, d} = NoteDrafts.upsert(a, %{"text" => "hello"})
      assert {:ok, d2} = NoteDrafts.upsert(a, %{"text" => "hello again", "sensitive" => true})
      assert d.id == d2.id
      assert %{text: "hello again", sensitive: true} = NoteDrafts.get(a)

      assert :ok = NoteDrafts.delete(a)
      assert :ok = NoteDrafts.delete(a)
      assert NoteDrafts.get(a) == nil
    end

    test "a bad visibility is a changeset error" do
      a = account!()
      assert {:error, %Ecto.Changeset{}} = NoteDrafts.upsert(a, %{"visibility" => "nope"})
    end
  end
end
