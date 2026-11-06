# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiShared.DeliverySuspension.CacheTest do
  # One named table per VM.
  use ExUnit.Case, async: false

  alias SukhiShared.DeliverySuspension.{Cache, Notice}

  @now ~U[2026-11-06 12:00:00Z]

  defp notice(overrides) do
    struct!(
      %Notice{
        id: "https://social.example/suspensions/1",
        controller: "https://social.example/users/ops",
        target_kind: :origin,
        target: "https://other.example",
        revision: 1,
        published: @now,
        effective_start: @now,
        accepted_at: @now
      },
      overrides
    )
  end

  test "with no table, nothing is held (the delivery node outside the gateway's VM)" do
    assert [] = Cache.candidates("https://other.example/inbox")
    assert [] = Cache.all()
    assert :ok = Cache.put(notice([]))
  end

  describe "with the owner running" do
    setup do
      start_supervised!(Cache)
      :ok
    end

    test "an origin notice and an inbox notice are found for their own URLs only" do
      origin = notice([])

      inbox =
        notice(
          id: "https://social.example/suspensions/2",
          target_kind: :inbox,
          target: "https://third.example/inbox"
        )

      Cache.put(origin)
      Cache.put(inbox)

      assert [^origin] = Cache.candidates("https://other.example/users/a/inbox")
      assert [^inbox] = Cache.candidates("https://third.example/inbox")
      assert [] = Cache.candidates("https://third.example/other-inbox")
      # the origin is computed from the URL, so another port or subdomain is not it
      assert [] = Cache.candidates("https://other.example:8443/inbox")
      assert [] = Cache.candidates("https://www.other.example/inbox")
      assert [] = Cache.candidates("not a url")
      assert [] = Cache.candidates(nil)
    end

    test "a cancelled notice is dropped, an active one replaces itself" do
      Cache.put(notice([]))
      Cache.put(notice(revision: 2, summary: "later"))
      assert [%Notice{revision: 2}] = Cache.all()

      Cache.put(notice(status: :cancelled, revision: 3))
      assert [] = Cache.all()
    end

    test "replace/1 is the rebuild: it keeps the active ones and forgets the rest" do
      Cache.put(notice(id: "https://social.example/suspensions/old"))

      Cache.replace([
        notice(id: "https://social.example/suspensions/a"),
        notice(id: "https://social.example/suspensions/b", status: :cancelled)
      ])

      assert [%Notice{id: "https://social.example/suspensions/a"}] = Cache.all()
    end
  end
end
