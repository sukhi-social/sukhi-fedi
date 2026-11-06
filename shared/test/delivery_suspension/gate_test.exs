# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiShared.DeliverySuspension.GateTest do
  use ExUnit.Case, async: true

  alias SukhiShared.DeliverySuspension.{Gate, Notice, Policy}

  @policy Policy.default()
  @inbox "https://other.example/users/a/inbox"
  @shared "https://other.example/inbox"

  defp at(h, m \\ 0, s \\ 0), do: DateTime.new!(~D[2026-11-06], Time.new!(h, m, s), "Etc/UTC")

  # An accepted notice: published 00:00, effective from 01:00, ending 03:00.
  defp notice(overrides \\ []) do
    base = %Notice{
      id: "https://social.example/suspensions/1",
      controller: "https://social.example/users/ops",
      target_kind: :origin,
      target: "https://other.example",
      revision: 1,
      published: at(0),
      start_time: at(1),
      end_time: at(3),
      effective_start: at(1),
      accepted_at: at(0, 5)
    }

    struct!(base, overrides)
  end

  defp suspended?(url, now, notices), do: Gate.suspended?(url, now, notices, @policy)

  describe "the window: effective_start <= now < effective end" do
    test "just before, at, just after the start; just before, at the end" do
      n = [notice()]
      refute suspended?(@inbox, at(0, 59, 59), n)
      assert suspended?(@inbox, at(1), n)
      assert suspended?(@inbox, at(1, 0, 1), n)
      assert suspended?(@inbox, at(2, 59, 59), n)
      refute suspended?(@inbox, at(3), n)
      refute suspended?(@inbox, at(3, 0, 1), n)
    end
  end

  describe "scope" do
    test "an origin notice covers every inbox of that exact origin" do
      n = [notice()]
      assert suspended?(@inbox, at(2), n)
      assert suspended?(@shared, at(2), n)
      assert suspended?("https://OTHER.example:443/users/b/inbox", at(2), n)
    end

    test "another port and a subdomain are other origins" do
      n = [notice()]
      refute suspended?("https://other.example:8443/inbox", at(2), n)
      refute suspended?("https://sub.other.example/inbox", at(2), n)
      refute suspended?("https://other.example./inbox", at(2), n)
      refute suspended?("https://another.example/inbox", at(2), n)
    end

    test "an inbox notice is the exact URL, so the shared inbox is not covered by it" do
      n = [notice(target_kind: :inbox, target: @inbox)]
      assert suspended?(@inbox, at(2), n)
      refute suspended?(@shared, at(2), n)
      refute suspended?(@inbox <> "?x=1", at(2), n)
    end

    test "a URL we cannot read an origin from is delivered as usual" do
      n = [notice()]
      refute suspended?("http://other.example/inbox", at(2), n)
      refute suspended?("https://0x7f.1/inbox", at(2), n)
      refute suspended?("not a url", at(2), n)
      refute Gate.suspended?(nil, at(2), n, @policy)
    end
  end

  describe "what is in effect" do
    test "a notice nobody accepted is not in effect" do
      refute suspended?(@inbox, at(2), [notice(accepted_at: nil)])
      refute suspended?(@inbox, at(2), [notice(effective_start: nil)])
    end

    test "a cancelled notice is not in effect, whatever its window says" do
      refute suspended?(@inbox, at(2), [notice(status: :cancelled)])
      refute suspended?(@inbox, at(2), [notice(cancelled_at: at(1, 30))])
    end

    test "one notice ending does not end the others; any one keeps it suspended" do
      short = notice(end_time: at(2))
      long = notice(id: "https://social.example/suspensions/2", end_time: at(5))
      assert suspended?(@inbox, at(1, 30), [short, long])
      refute suspended?(@inbox, at(2, 30), [short])
      assert suspended?(@inbox, at(2, 30), [short, long])
      refute suspended?(@inbox, at(5), [short, long])
    end

    test "no notices, none for this target" do
      refute suspended?(@inbox, at(2), [])
      refute suspended?(@inbox, at(2), [notice(target: "https://elsewhere.example")])
    end
  end

  describe "effective_end/2: the earliest of four, and it never moves later" do
    test "endTime" do
      assert Gate.effective_end(notice(end_time: at(2)), @policy) == at(2)
    end

    test "the proof's expiry, when it is the one we rely on" do
      assert Gate.effective_end(notice(proof_expires_at: at(1, 30)), @policy) == at(1, 30)
    end

    test "published + the notice age limit" do
      policy = %Policy{notice_max_age: 2 * 3600}
      n = notice(end_time: at(20), effective_start: at(1))
      assert Gate.effective_end(n, policy) == at(2)
    end

    test "effective_start + the longest suspension, even when endTime is absent or far" do
      assert Gate.effective_end(notice(end_time: nil), @policy) ==
               DateTime.add(at(1), 48 * 3600, :second)

      far = ~U[2027-01-01 00:00:00Z]

      assert Gate.effective_end(notice(end_time: far), @policy) ==
               DateTime.add(at(1), 48 * 3600, :second)
    end

    test "a later revision with a later endTime cannot go past the cap from the same effective_start" do
      pushed = notice(revision: 9, end_time: ~U[2030-01-01 00:00:00Z])
      assert Gate.effective_end(pushed, @policy) == DateTime.add(at(1), 48 * 3600, :second)
      refute suspended?(@inbox, DateTime.add(at(1), 48 * 3600, :second), [pushed])
    end
  end

  describe "resume_at/4" do
    test "the latest effective end among the notices in effect for that URL" do
      a = notice(end_time: at(2))
      b = notice(id: "https://social.example/suspensions/2", end_time: at(4))

      other =
        notice(
          id: "https://social.example/suspensions/3",
          target: "https://x.example",
          end_time: at(9)
        )

      assert Gate.resume_at(@inbox, at(1, 30), [a, b, other], @policy) == at(4)
    end

    test "nil when it is not suspended" do
      assert Gate.resume_at(@inbox, at(0, 30), [notice()], @policy) == nil
      assert Gate.resume_at(@inbox, at(3), [notice()], @policy) == nil
      assert Gate.resume_at("nope", at(2), [notice()], @policy) == nil
    end
  end

  describe "exempt?/1: what suspension never holds back" do
    @notice_object %{
      "type" => "DeliverySuspension",
      "id" => "https://social.example/suspensions/1"
    }

    test "Create and Update of a notice" do
      assert Gate.exempt?(%{"type" => "Create", "object" => @notice_object})
      assert Gate.exempt?(%{"type" => "Update", "object" => @notice_object})

      assert Gate.exempt?(%{
               "type" => "Create",
               "object" => %{"type" => ["Object", "DeliverySuspension"]}
             })
    end

    test "Undo of a Create of a notice, judged by the Create's content" do
      create = %{"type" => "Create", "object" => @notice_object}
      assert Gate.exempt?(%{"type" => "Undo", "object" => create})
    end

    test "ordinary activities are held" do
      refute Gate.exempt?(%{"type" => "Create", "object" => %{"type" => "Note"}})
      refute Gate.exempt?(%{"type" => "Update", "object" => %{"type" => "Person"}})
      refute Gate.exempt?(%{"type" => "Undo", "object" => %{"type" => "Follow"}})

      refute Gate.exempt?(%{
               "type" => "Undo",
               "object" => %{"type" => "Create", "object" => %{"type" => "Note"}}
             })

      refute Gate.exempt?(%{"type" => "Follow", "object" => @notice_object})
      refute Gate.exempt?(%{"type" => "Announce", "object" => @notice_object})
    end

    test "an Undo that only names an id, and anything that is not an activity" do
      refute Gate.exempt?(%{"type" => "Undo", "object" => "https://social.example/activities/1"})

      refute Gate.exempt?(%{
               "type" => "Create",
               "object" => "https://social.example/suspensions/1"
             })

      refute Gate.exempt?(%{"type" => "Create"})
      refute Gate.exempt?(nil)
      refute Gate.exempt?("Create")
    end
  end
end
