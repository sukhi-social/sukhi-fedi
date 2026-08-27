# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiDelivery.Outbox.DispatchWorkerTest do
  use ExUnit.Case, async: true

  alias SukhiDelivery.Outbox.DispatchWorker, as: DW

  describe "backoff/1" do
    test "ramps with the attempt and clamps to the last step" do
      assert DW.backoff(%Oban.Job{attempt: 1}) == 5
      assert DW.backoff(%Oban.Job{attempt: 2}) == 10
      assert DW.backoff(%Oban.Job{attempt: 100}) == 300
    end

    test "one backoff step is defined for every retry before the discard" do
      # The last attempt fails into `discarded`, so it never waits.
      assert DW.backoff(%Oban.Job{attempt: DW.max_attempts() - 1}) == 300
    end
  end
end
