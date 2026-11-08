# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Fedi.DeliverySuspension.HintTest do
  # A delivery's Link header points at a notice: it is fetched and judged like
  # any other, and it suspends nothing on its own. Real `dtlv`, the web stood in for.
  use SukhiFedi.GraphCase

  alias SukhiFedi.Fedi.DeliverySuspension.{Control, Hint, Store}
  alias SukhiFedi.SuspensionNet, as: Net
  alias SukhiShared.DeliverySuspension.Cache

  @ctl "https://rest.example/users/ops"
  @inbox "https://rest.example/users/ops/inbox"
  @url "https://rest.example/suspensions/1"
  @now ~U[2026-11-06 12:00:00Z]

  defp notice(attrs \\ %{}) do
    Map.merge(
      %{
        "id" => @url,
        "type" => "DeliverySuspension",
        "attributedTo" => @ctl,
        "targetInbox" => @inbox,
        "revision" => 1,
        "published" => DateTime.to_iso8601(DateTime.add(@now, -60, :second)),
        "endTime" => DateTime.to_iso8601(DateTime.add(@now, 3600, :second))
      },
      attrs
    )
  end

  defp linked do
    %{
      @ctl => Net.json(%{"id" => @ctl, "inbox" => @inbox}),
      @inbox => Net.json(%{"id" => @inbox, "inboxOf" => @ctl})
    }
  end

  defp web(doc \\ notice(), extra \\ linked()), do: Map.put(extra, @url, Net.json(doc))

  defp run(web, opts \\ []) do
    Hint.run(
      @url,
      @now,
      Keyword.merge(
        [
          http: Net.http(web),
          control: fn n, now -> Control.verify(n, now, http: Net.http(web)) end
        ],
        opts
      )
    )
  end

  setup do
    start_supervised!(Cache)
    :ok
  end

  test "a notice at the address, from its controller's own host and confirmed, is taken" do
    assert {:ok, :accepted} = run(web())
    assert {:ok, %{target: @inbox, accepted_at: %DateTime{}}, _} = Store.get_notice(@url)
    assert [_] = Cache.candidates(@inbox)
  end

  test "the hint alone suspends nothing: the controller must link back" do
    nolink = web(notice(), %{linked() | @inbox => Net.json(%{"id" => @inbox})})
    assert {:error, {:unlinked, :inbox_of}} = run(nolink)
    assert :none = Store.get_notice(@url)
    assert [] = Cache.candidates(@inbox)
  end

  test "a web that cannot confirm is not a reason to take it" do
    down = Map.put(%{@ctl => Net.status(503)}, @url, Net.json(notice()))
    assert {:error, {:unreachable, :unavailable}} = run(down)
    assert :none = Store.get_notice(@url)
  end

  test "the document must be the one the Link named, and a notice" do
    other = notice(%{"id" => "https://rest.example/suspensions/2"})
    assert {:error, :id_is_not_the_link} = run(web(other))

    note = %{"id" => @url, "type" => "Note", "attributedTo" => @ctl}
    assert {:error, :not_a_notice} = run(web(note))
  end

  test "a notice about someone else's host, served from here, is refused" do
    # served from rest.example, claiming a controller elsewhere
    alien = notice(%{"attributedTo" => "https://evil.example/users/x"})
    assert {:error, :signer_mismatch} = run(web(alien))
    assert :none = Store.get_notice(@url)
  end

  test "a redirect out of the origin is not followed to a verdict" do
    moved = "https://elsewhere.example/n/1"
    web = Map.merge(linked(), %{@url => Net.redirect(moved), moved => Net.json(notice())})
    assert {:error, :moved_to_another_origin} = run(web)
    assert :none = Store.get_notice(@url)
  end

  test "an unreadable address is reported as unreachable, so the job is tried again only for 'unavailable'" do
    assert {:error, {:unreachable, :unavailable}} = run(%{@url => Net.status(503)})
    assert {:error, {:unreachable, :gone}} = run(%{@url => Net.status(404)})

    assert {:error, {:unreachable, :bad_document}} =
             run(%{@url => Net.json(%{}, type: "text/html")})
  end

  test "a cancellation found at the address ends what we hold" do
    assert {:ok, :accepted} = run(web())

    cancelled = notice(%{"revision" => 2, "status" => "cancelled"})

    assert {:ok, :cancelled} =
             run(web(cancelled), control: fn _, _ -> {:error, :must_not_ask} end)

    assert {:ok, %{status: :cancelled}, _} = Store.get_notice(@url)
    assert [] = Cache.candidates(@inbox)
  end

  test "the same notice again changes nothing" do
    assert {:ok, :accepted} = run(web())
    assert {:ok, :unchanged} = run(web())
  end
end
