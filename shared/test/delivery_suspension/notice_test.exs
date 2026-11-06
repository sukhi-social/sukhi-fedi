# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiShared.DeliverySuspension.NoticeTest do
  use ExUnit.Case, async: true

  alias SukhiShared.DeliverySuspension.{Notice, Policy}

  @controller "https://social.example/users/ops"

  defp doc(overrides \\ %{}) do
    Map.merge(
      %{
        "@context" => ["https://www.w3.org/ns/activitystreams", "https://w3id.org/fep/f799"],
        "type" => "DeliverySuspension",
        "id" => "https://social.example/suspensions/1",
        "attributedTo" => @controller,
        "targetOrigin" => "https://other.example",
        "revision" => 1,
        "published" => "2026-11-06T00:00:00Z",
        "startTime" => "2026-11-06T01:00:00Z",
        "endTime" => "2026-11-06T03:00:00Z",
        "summary" => "maintenance",
        "url" => "https://social.example/status"
      },
      overrides
    )
  end

  defp drop(map, keys), do: Map.drop(map, keys)

  describe "parse/2" do
    test "a well-formed notice becomes a struct, undecided until it is accepted" do
      assert {:ok, %Notice{} = n} = Notice.parse(doc())
      assert n.id == "https://social.example/suspensions/1"
      assert n.controller == @controller
      assert n.target_kind == :origin
      assert n.target == "https://other.example"
      assert n.revision == 1
      assert n.status == :active
      assert n.start_time == ~U[2026-11-06 01:00:00Z]
      assert n.end_time == ~U[2026-11-06 03:00:00Z]
      assert n.announcement == nil
      # what we decide on accepting is not read from the document
      assert n.effective_start == nil and n.accepted_at == nil and n.cancelled_at == nil
    end

    test "the target is normalized for an origin, kept as written for an inbox" do
      d =
        doc()
        |> drop(["targetOrigin"])
        |> Map.put("targetInbox", "https://Other.example/users/a/inbox")

      assert {:ok, %Notice{target_kind: :inbox, target: "https://Other.example/users/a/inbox"}} =
               Notice.parse(d)

      assert {:ok, %Notice{target: "https://other.example:8443"}} =
               Notice.parse(doc(%{"targetOrigin" => "HTTPS://Other.Example:8443/"}))
    end

    test "exactly one target" do
      assert {:error, :two_targets} =
               Notice.parse(doc(%{"targetInbox" => "https://other.example/inbox"}))

      assert {:error, :no_target} = Notice.parse(drop(doc(), ["targetOrigin"]))

      assert {:error, :bad_target} =
               Notice.parse(doc(%{"targetOrigin" => "https://other.example/users/a"}))

      assert {:error, :bad_target} = Notice.parse(doc(%{"targetOrigin" => "https://0x7f.1"}))
      assert {:error, :bad_target} = Notice.parse(doc(%{"targetOrigin" => 42}))
    end

    test "revision is an integer in 1..2^53-1" do
      assert {:ok, %Notice{revision: 9_007_199_254_740_991}} =
               Notice.parse(doc(%{"revision" => 9_007_199_254_740_991}))

      assert {:error, :bad_revision} = Notice.parse(doc(%{"revision" => 0}))
      assert {:error, :bad_revision} = Notice.parse(doc(%{"revision" => 9_007_199_254_740_992}))
      assert {:error, :bad_revision} = Notice.parse(doc(%{"revision" => 1.5}))
      assert {:error, :bad_revision} = Notice.parse(doc(%{"revision" => 1.0}))
      assert {:error, :bad_revision} = Notice.parse(doc(%{"revision" => "1"}))
      assert {:error, :bad_revision} = Notice.parse(drop(doc(), ["revision"]))
    end

    test "times carry a time zone; the end is after the start" do
      assert {:ok, %Notice{start_time: ~U[2026-11-06 01:00:00Z]}} =
               Notice.parse(doc(%{"startTime" => "2026-11-06T10:00:00+09:00"}))

      assert {:error, :bad_time} = Notice.parse(doc(%{"published" => "2026-11-06T00:00:00"}))
      assert {:error, :bad_time} = Notice.parse(doc(%{"startTime" => "2026-11-06"}))
      assert {:error, :bad_time} = Notice.parse(doc(%{"endTime" => "tomorrow"}))
      assert {:error, :bad_time} = Notice.parse(drop(doc(), ["published"]))

      assert {:error, :end_before_start} =
               Notice.parse(doc(%{"endTime" => "2026-11-06T01:00:00Z"}))

      assert {:error, :end_before_start} =
               Notice.parse(doc(%{"endTime" => "2026-11-06T00:30:00Z"}))
    end

    test "startTime and endTime are optional" do
      assert {:ok, %Notice{start_time: nil, end_time: nil}} =
               Notice.parse(drop(doc(), ["startTime", "endTime"]))
    end

    test "status is active or cancelled" do
      assert {:ok, %Notice{status: :cancelled}} = Notice.parse(doc(%{"status" => "cancelled"}))
      assert {:ok, %Notice{status: :active}} = Notice.parse(doc(%{"status" => "active"}))
      assert {:error, :bad_status} = Notice.parse(doc(%{"status" => "paused"}))
    end

    test "the id, and the announcement, belong to the controller's origin" do
      assert {:error, :id_not_owned} =
               Notice.parse(doc(%{"id" => "https://evil.example/suspensions/1"}))

      assert {:error, :id_not_owned} =
               Notice.parse(doc(%{"id" => "https://sub.social.example/s/1"}))

      assert {:ok, %Notice{announcement: "https://social.example/activities/1"}} =
               Notice.parse(doc(%{"announcement" => "https://social.example/activities/1"}))

      assert {:ok, %Notice{announcement: "https://social.example/activities/1"}} =
               Notice.parse(
                 doc(%{"announcement" => %{"id" => "https://social.example/activities/1"}})
               )

      assert {:error, :id_not_owned} =
               Notice.parse(doc(%{"announcement" => "https://evil.example/activities/1"}))

      assert {:error, :bad_announcement} = Notice.parse(doc(%{"announcement" => 7}))
    end

    test "attributedTo is one actor, as an id or an object with an id" do
      assert {:ok, %Notice{controller: @controller}} =
               Notice.parse(doc(%{"attributedTo" => %{"id" => @controller}}))

      assert {:error, :bad_controller} = Notice.parse(doc(%{"attributedTo" => [@controller]}))
      assert {:error, :bad_controller} = Notice.parse(doc(%{"attributedTo" => "not a url"}))
      assert {:error, :bad_controller} = Notice.parse(drop(doc(), ["attributedTo"]))
    end

    test "the type must be DeliverySuspension (alone or in a list)" do
      assert {:ok, _} = Notice.parse(doc(%{"type" => ["Object", "DeliverySuspension"]}))
      assert {:error, :wrong_type} = Notice.parse(doc(%{"type" => "Note"}))
      assert {:error, :wrong_type} = Notice.parse(drop(doc(), ["type"]))
      assert {:error, :bad_id} = Notice.parse(doc(%{"id" => "http://social.example/s/1"}))
      assert {:error, :bad_id} = Notice.parse(drop(doc(), ["id"]))
    end

    test "nesting is bounded (default 8 levels)" do
      deep = Enum.reduce(1..8, "x", fn _, acc -> %{"a" => acc} end)
      assert {:error, :too_deep} = Notice.parse(doc(%{"extra" => deep}))
      assert {:ok, _} = Notice.parse(doc(%{"extra" => %{"a" => %{"b" => "c"}}}))
      assert {:ok, _} = Notice.parse(doc(%{"extra" => deep}), %Policy{notice_max_depth: 12})
    end

    test "not an object" do
      assert {:error, :not_an_object} = Notice.parse([])
      assert {:error, :not_an_object} = Notice.parse("DeliverySuspension")
      assert {:error, :not_an_object} = Notice.parse(nil)
    end
  end

  describe "depth/1" do
    test "counts levels of objects and arrays" do
      assert Notice.depth("x") == 0
      assert Notice.depth(%{}) == 1
      assert Notice.depth(%{"a" => 1}) == 1
      assert Notice.depth(%{"a" => %{"b" => [1, %{"c" => 2}]}}) == 4
      assert Notice.depth([[], [[]]]) == 3
    end
  end

  describe "same_immutable?/2" do
    setup do
      {:ok, old} = Notice.parse(doc())
      %{old: old}
    end

    test "a higher revision may change the rest", %{old: old} do
      {:ok, new} =
        Notice.parse(
          doc(%{"revision" => 2, "endTime" => "2026-11-06T05:00:00Z", "summary" => "longer"})
        )

      assert Notice.same_immutable?(old, new)
    end

    test "id, controller, published, announcement and target may not change", %{old: old} do
      for change <- [
            %{"id" => "https://social.example/suspensions/2"},
            %{"attributedTo" => "https://social.example/users/other"},
            %{"published" => "2026-11-06T00:00:01Z"},
            %{"announcement" => "https://social.example/activities/1"},
            %{"targetOrigin" => "https://other.example:8443"}
          ] do
        {:ok, new} = Notice.parse(doc(change))
        refute Notice.same_immutable?(old, new), "#{inspect(change)} must be refused"
      end
    end

    test "switching from an origin target to an inbox target is a change", %{old: old} do
      {:ok, new} =
        doc()
        |> drop(["targetOrigin"])
        |> Map.put("targetInbox", "https://other.example/inbox")
        |> Notice.parse()

      refute Notice.same_immutable?(old, new)
    end

    test "the same instant in another zone is the same published", %{old: old} do
      {:ok, new} = Notice.parse(doc(%{"published" => "2026-11-06T09:00:00+09:00"}))
      assert Notice.same_immutable?(old, new)
    end
  end
end
