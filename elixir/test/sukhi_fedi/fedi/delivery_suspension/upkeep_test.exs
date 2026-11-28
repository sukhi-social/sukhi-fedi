# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Fedi.DeliverySuspension.UpkeepTest do
  # The gateway's half of the delivery worker's cache: filled on accept,
  # rebuilt from the store on start, trimmed by the sweep. Real PostgreSQL.
  use SukhiFedi.IntegrationCase, async: false

  import Ecto.Query, only: [from: 2]

  @moduletag :integration

  alias SukhiFedi.Fedi.DeliverySuspension.{Admin, Receiver, Store, Upkeep}
  alias SukhiShared.DeliverySuspension.{Cache, Gate, Policy}

  @alice "https://a.example/users/alice"
  @now ~U[2026-11-06 12:00:00Z]
  @inbox "https://b.example/inbox"

  defp activity(type, object, id),
    do: %{"id" => id, "type" => type, "actor" => @alice, "object" => object}

  defp notice(attrs \\ %{}) do
    Map.merge(
      %{
        "id" => "https://a.example/suspensions/1",
        "type" => "DeliverySuspension",
        "attributedTo" => @alice,
        "targetInbox" => @inbox,
        "revision" => 1,
        "published" => DateTime.to_iso8601(DateTime.add(@now, -60, :second)),
        "endTime" => DateTime.to_iso8601(DateTime.add(@now, 3600, :second))
      },
      attrs
    )
  end

  defp recv(activity, extra \\ []) do
    Receiver.handle(
      activity,
      Keyword.merge([signer_host: "a.example", now: @now, control: fn _, _ -> :ok end], extra)
    )
  end

  defp resume_at, do: Gate.resume_at(@inbox, @now, Cache.candidates(@inbox), Policy.default())

  setup do
    start_supervised!(Cache)
    :ok
  end

  test "an accepted notice reaches the worker's cache, and its cancellation leaves it" do
    assert [] = Cache.candidates(@inbox)
    assert {:ok, :accepted} = recv(activity("Create", notice(), "https://a.example/a/c1"))
    assert resume_at() == DateTime.add(@now, 3600, :second)

    assert {:ok, :cancelled} =
             recv(activity("Undo", "https://a.example/a/c1", "https://a.example/a/u1"))

    assert [] = Cache.candidates(@inbox)
  end

  test "after a restart the same inbox rests until the same time" do
    assert {:ok, :accepted} = recv(activity("Create", notice(), "https://a.example/a/c1"))
    before = resume_at()
    assert %DateTime{} = before

    # the cache is a copy and dies with the VM; the store is what is left
    stop_supervised!(Cache)
    start_supervised!(Cache)
    assert [] = Cache.candidates(@inbox)

    start_supervised!(Upkeep)
    assert :ok = Upkeep.reload()

    assert resume_at() == before
  end

  test "a cancelled notice is not brought back by a restart" do
    assert {:ok, :accepted} = recv(activity("Create", notice(), "https://a.example/a/c1"))

    assert {:ok, :cancelled} =
             recv(activity("Undo", "https://a.example/a/c1", "https://a.example/a/u1"))

    stop_supervised!(Cache)
    start_supervised!(Cache)
    start_supervised!(Upkeep)
    assert :ok = Upkeep.reload()

    assert [] = Cache.candidates(@inbox)
  end

  test "the sweep forgets what is past the age limit, in the store and in the cache" do
    assert {:ok, :accepted} = recv(activity("Create", notice(), "https://a.example/a/c1"))
    start_supervised!(Upkeep)
    assert :ok = Upkeep.reload()
    assert [_] = Cache.all()

    later = DateTime.add(@now, 15 * 86_400, :second)
    assert %{notices: 1} = Upkeep.sweep(later)
    assert [] = Cache.all()
  end

  describe "an admin ignores a rest" do
    @id "https://a.example/suspensions/1"

    test "deliveries go out at once; the peer's record is untouched; un-ignoring brings it back" do
      start_supervised!(Upkeep)
      assert {:ok, :accepted} = recv(activity("Create", notice(), "https://a.example/a/c1"))
      assert %DateTime{} = resume_at()
      {:ok, record, _} = Store.get_notice(@id)

      assert :ok = Admin.ignore(@id)
      assert nil == resume_at()
      assert [@id] = Cache.ignored()
      assert {:ok, ^record, _} = Store.get_notice(@id)

      assert :ok = Admin.unignore(@id)
      assert %DateTime{} = resume_at()
      assert {:ok, ^record, _} = Store.get_notice(@id)
    end

    test "a later revision stays ignored, and the choice survives a restart" do
      start_supervised!(Upkeep)
      assert {:ok, :accepted} = recv(activity("Create", notice(), "https://a.example/a/c1"))
      assert :ok = Admin.ignore(@id)

      assert {:ok, :accepted} =
               recv(activity("Update", notice(%{"revision" => 2}), "https://a.example/a/u1"))

      assert nil == resume_at()

      stop_supervised!(Cache)
      start_supervised!(Cache)
      assert :ok = Upkeep.reload()
      assert nil == resume_at()
      assert [@id] = Cache.ignored()
    end

    test "a notice we do not have is not found" do
      start_supervised!(Upkeep)
      assert {:error, :not_found} = Admin.ignore("https://a.example/suspensions/none")
      assert {:error, :not_found} = Admin.unignore(nil)
    end

    test "the choice is written to the admin audit trail" do
      start_supervised!(Upkeep)
      assert {:ok, :accepted} = recv(activity("Create", notice(), "https://a.example/a/c1"))
      assert :ok = Admin.ignore(@id)

      assert [%{action: "suspension_ignored", target_domain: "b.example"}] =
               SukhiFedi.AccountRepo.all(
                 from(a in SukhiFedi.Schema.AdminAudit,
                   where: like(a.action, "suspension_%"),
                   select: %{action: a.action, target_domain: a.target_domain}
                 )
               )
    end

    test "forgetting the notice forgets the ignore" do
      start_supervised!(Upkeep)
      assert {:ok, :accepted} = recv(activity("Create", notice(), "https://a.example/a/c1"))
      assert :ok = Admin.ignore(@id)

      Upkeep.sweep(DateTime.add(@now, 15 * 86_400, :second))
      assert {:ok, %{} = ignored} = Store.ignored()
      assert ignored == %{}
    end
  end
end
