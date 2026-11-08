# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Fedi.DeliverySuspension.RecheckTest do
  # Looking again at a notice we hold: a link that is gone withdraws it, an
  # unreadable web changes nothing. Real `dtlv`, the web stood in for.
  use SukhiFedi.GraphCase

  alias SukhiFedi.Fedi.DeliverySuspension.{Receiver, Recheck, Store}
  alias SukhiFedi.SuspensionNet, as: Net
  alias SukhiShared.DeliverySuspension.{Cache, Gate, Policy}

  @alice "https://a.example/users/alice"
  @inbox "https://a.example/users/alice/inbox"
  @notice_id "https://a.example/suspensions/1"
  @create_id "https://a.example/activities/c1"
  @now ~U[2026-11-06 12:00:00Z]
  @hour 3600

  defp later(seconds), do: DateTime.add(@now, seconds, :second)

  defp web(overrides \\ %{}) do
    Map.merge(
      %{
        @alice => Net.json(%{"id" => @alice, "inbox" => @inbox}),
        @inbox => Net.json(%{"id" => @inbox, "inboxOf" => @alice})
      },
      overrides
    )
  end

  defp notice(attrs \\ %{}) do
    Map.merge(
      %{
        "id" => @notice_id,
        "type" => "DeliverySuspension",
        "attributedTo" => @alice,
        "targetInbox" => @inbox,
        "revision" => 1,
        "published" => DateTime.to_iso8601(later(-60)),
        "endTime" => DateTime.to_iso8601(later(6 * @hour))
      },
      attrs
    )
  end

  defp create(object \\ notice()),
    do: %{"id" => @create_id, "type" => "Create", "actor" => @alice, "object" => object}

  # Take the notice as the real check would, at `@now`, against `web`.
  defp take(activity \\ create(), web \\ web()) do
    Receiver.handle(activity,
      signer_host: "a.example",
      now: @now,
      control: fn n, now ->
        SukhiFedi.Fedi.DeliverySuspension.Control.verify(n, now, http: Net.http(web))
      end
    )
  end

  defp recheck(at, web, opts \\ []),
    do: Recheck.run(at, Keyword.merge([http: Net.http(web)], opts))

  defp resting?(at),
    do: Gate.suspended?(@inbox, at, Cache.candidates(@inbox), Policy.default())

  defp flush_requests do
    receive do
      {:requested, _, _} -> flush_requests()
    after
      0 -> :ok
    end
  end

  setup do
    start_supervised!(Cache)
    :ok
  end

  test "a link that still holds renews the evidence and changes nothing else" do
    assert {:ok, :accepted} = take()
    at = later(@hour)

    assert %{checked: 1, withdrawn: 0} = recheck(at, web())
    assert {:ok, %{verified_at: v, attempted_at: a}} = Store.get_evidence(:inbox, @inbox, @alice)
    assert DateTime.compare(v, at) == :eq and DateTime.compare(a, at) == :eq
    assert resting?(at)
  end

  test "a link that is gone withdraws the notice: it stays, but nothing rests on it" do
    assert {:ok, :accepted} = take()
    assert resting?(@now)

    gone = web(%{@inbox => Net.json(%{"id" => @inbox})})
    assert %{checked: 1, withdrawn: 1} = recheck(later(@hour), gone)

    assert {:ok, %{accepted_at: nil, status: :active, revision: 1}, @create_id} =
             Store.get_notice(@notice_id)

    refute resting?(later(@hour))
    assert [] = Cache.candidates(@inbox)
  end

  test "a web that cannot be read changes nothing, and is only recorded" do
    assert {:ok, :accepted} = take()
    at = later(@hour)

    assert %{checked: 1, withdrawn: 0, unreachable: 1} = recheck(at, %{@alice => Net.status(503)})
    assert resting?(at)

    assert {:ok, %{failure: :unavailable, verified_at: v}} =
             Store.get_evidence(:inbox, @inbox, @alice)

    assert DateTime.compare(v, @now) == :eq
  end

  test "a notice looked at a moment ago is not looked at again" do
    assert {:ok, :accepted} = take()
    flush_requests()

    assert %{checked: 0} = recheck(later(60), web())
    refute_received {:requested, _, _}

    assert %{checked: 1} = recheck(later(60), web(), every: 30)
  end

  test "a notice that is over, or cancelled, is not looked at" do
    assert {:ok, :accepted} = take()

    assert %{checked: 0} = recheck(later(7 * @hour), web())

    assert {:ok, :cancelled} =
             Receiver.handle(
               %{
                 "id" => "https://a.example/activities/u1",
                 "type" => "Undo",
                 "actor" => @alice,
                 "object" => @create_id
               },
               signer_host: "a.example",
               now: later(10)
             )

    assert %{checked: 0} = recheck(later(@hour), web())
  end

  test "the same revision is taken again through the ordinary check, keeping its start" do
    assert {:ok, :accepted} = take()
    {:ok, %{effective_start: start}, _} = Store.get_notice(@notice_id)

    assert %{withdrawn: 1} = recheck(later(@hour), web(%{@inbox => Net.json(%{"id" => @inbox})}))
    refute resting?(later(@hour))

    # the link comes back; the controller sends the notice again
    again =
      Receiver.handle(create(),
        signer_host: "a.example",
        now: later(2 * @hour),
        control: fn n, now ->
          SukhiFedi.Fedi.DeliverySuspension.Control.verify(n, now, http: Net.http(web()))
        end
      )

    assert {:ok, :accepted} = again

    assert {:ok, %{accepted_at: %DateTime{}, effective_start: ^start}, _} =
             Store.get_notice(@notice_id)

    assert resting?(later(2 * @hour))
  end
end
