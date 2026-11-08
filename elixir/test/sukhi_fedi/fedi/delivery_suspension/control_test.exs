# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Fedi.DeliverySuspension.ControlTest do
  # Evidence is written to the store: real `dtlv`.
  use SukhiFedi.GraphCase

  alias SukhiFedi.Fedi.DeliverySuspension.{Control, Store}
  alias SukhiFedi.SuspensionNet, as: Net
  alias SukhiShared.DeliverySuspension.Notice

  @now ~U[2026-11-06 12:00:00Z]
  @controller "https://ops.example/users/ops"
  @rel "https://w3id.org/fep/f799#deliveryController"

  defp notice(target_kind, target) do
    %Notice{
      id: "https://ops.example/suspensions/1",
      controller: @controller,
      target_kind: target_kind,
      target: target,
      revision: 1,
      published: @now
    }
  end

  # A clock that moves a minute with each call, so the 30-second throttle after
  # a failure is not what a test trips over; tests of the throttle say `now`.
  defp tick, do: DateTime.add(@now, System.unique_integer([:positive, :monotonic]) * 60, :second)

  defp verify(notice, web, now \\ nil),
    do: Control.verify(notice, now || tick(), http: Net.http(web))

  defp actor(extra \\ %{}), do: Map.merge(%{"id" => @controller, "type" => "Person"}, extra)

  describe "a personal inbox" do
    @inbox "https://ops.example/users/ops/inbox"

    defp personal(overrides \\ %{}) do
      %{
        @controller => Net.json(actor(%{"inbox" => @inbox})),
        @inbox => Net.json(Map.merge(%{"id" => @inbox, "inboxOf" => @controller}, overrides))
      }
    end

    test "is confirmed when the actor's inbox is it and inboxOf points back" do
      assert :ok = verify(notice(:inbox, @inbox), personal())
    end

    test "inboxOf may be an object with an id" do
      web = personal(%{"inboxOf" => %{"id" => @controller}})
      assert :ok = verify(notice(:inbox, @inbox), web)
    end

    test "is not, when inboxOf names somebody else, or nobody" do
      assert {:error, {:unlinked, :inbox_of}} =
               verify(notice(:inbox, @inbox), personal(%{"inboxOf" => "https://other.example/u"}))

      web = %{personal() | @inbox => Net.json(%{"id" => @inbox})}
      assert {:error, {:unlinked, :inbox_of}} = verify(notice(:inbox, @inbox), web)
    end

    test "is not, when it is not the controller's inbox at all" do
      other = "https://ops.example/users/someone-else/inbox"

      assert {:error, {:unlinked, :not_the_actors_inbox}} =
               verify(notice(:inbox, other), personal())
    end

    test "is not, when the actor document is for another id" do
      web = %{
        personal()
        | @controller => Net.json(%{"id" => "https://evil.example/u", "inbox" => @inbox})
      }

      assert {:error, {:unlinked, :actor_id}} = verify(notice(:inbox, @inbox), web)
    end
  end

  describe "a shared inbox" do
    @shared "https://ops.example/inbox"

    defp shared(overrides \\ %{}) do
      %{
        @controller =>
          Net.json(
            actor(%{
              "inbox" => @controller <> "/inbox",
              "endpoints" => %{"sharedInbox" => @shared}
            })
          ),
        @shared =>
          Net.json(Map.merge(%{"id" => @shared, "deliveryController" => @controller}, overrides))
      }
    end

    test "is confirmed by deliveryController and the actor's sharedInbox" do
      assert :ok = verify(notice(:inbox, @shared), shared())
    end

    test "inboxOf does not stand in for deliveryController" do
      web = shared(%{"deliveryController" => nil, "inboxOf" => @controller})
      assert {:error, {:unlinked, :delivery_controller}} = verify(notice(:inbox, @shared), web)
    end

    test "must be one actor: two are not enough, one of them being the controller" do
      web = shared(%{"deliveryController" => [@controller, "https://other.example/u"]})
      assert {:error, {:unlinked, :delivery_controller}} = verify(notice(:inbox, @shared), web)
    end

    test "the actor must point at it" do
      web = %{shared() | @controller => Net.json(actor(%{"inbox" => @controller <> "/inbox"}))}
      assert {:error, {:unlinked, :not_the_actors_inbox}} = verify(notice(:inbox, @shared), web)
    end
  end

  describe "an origin" do
    @origin "https://rest.example"
    @finger "https://rest.example/.well-known/webfinger?resource=https%3A%2F%2Frest.example"

    defp jrd(links, subject \\ @origin),
      do: Net.json(%{"subject" => subject, "links" => links}, type: "application/jrd+json")

    defp link(href \\ @controller, rel \\ @rel), do: %{"rel" => rel, "href" => href}

    defp origin_web(overrides \\ %{}) do
      Map.merge(
        %{
          @finger => jrd([link()]),
          @controller => Net.json(actor(%{"controlledOrigin" => [@origin]}))
        },
        overrides
      )
    end

    test "is confirmed by WebFinger on the origin itself and the actor's controlledOrigin" do
      assert :ok = verify(notice(:origin, @origin), origin_web())
      assert_received {:requested, @finger, _}
    end

    test "the port is kept: the question is asked of that origin" do
      origin = "https://rest.example:8443"

      finger =
        "https://rest.example:8443/.well-known/webfinger?resource=https%3A%2F%2Frest.example%3A8443"

      web =
        origin_web(%{
          finger => jrd([link()], origin),
          @controller => Net.json(actor(%{"controlledOrigin" => origin}))
        })

      assert :ok = verify(notice(:origin, origin), web)
      refute_received {:requested, @finger, _}
    end

    test "the subject must be that origin" do
      web = origin_web(%{@finger => jrd([link()], "https://elsewhere.example")})
      assert {:error, {:unlinked, :subject}} = verify(notice(:origin, @origin), web)
    end

    test "a rel filter in the query is not believed: the links are read one by one" do
      noise = [
        link("https://x.example/a", "self"),
        link("https://x.example/b", "http://webfinger.net/rel/profile-page")
      ]

      assert :ok =
               verify(notice(:origin, @origin), origin_web(%{@finger => jrd(noise ++ [link()])}))

      only_noise = origin_web(%{@finger => jrd(noise)})

      assert {:error, {:unlinked, :not_exactly_one_link}} =
               verify(notice(:origin, @origin), only_noise)
    end

    test "exactly one link of the rel: two, even naming the same actor, is not" do
      web = origin_web(%{@finger => jrd([link(), link("https://other.example/u")])})
      assert {:error, {:unlinked, :not_exactly_one_link}} = verify(notice(:origin, @origin), web)
    end

    test "the link must name the controller, and the actor must list the origin" do
      web = origin_web(%{@finger => jrd([link("https://other.example/u")])})
      assert {:error, {:unlinked, :link_names_another}} = verify(notice(:origin, @origin), web)

      web =
        origin_web(%{
          @controller => Net.json(actor(%{"controlledOrigin" => ["https://another.example"]}))
        })

      assert {:error, {:unlinked, :origin_not_controlled}} = verify(notice(:origin, @origin), web)

      web = origin_web(%{@controller => Net.json(actor())})
      assert {:error, {:unlinked, :origin_not_controlled}} = verify(notice(:origin, @origin), web)
    end

    test "a redirect is followed, and the subject is still the original origin" do
      moved = "https://elsewhere.example/finger"
      web = origin_web(%{@finger => Net.redirect(moved), moved => jrd([link()])})
      assert :ok = verify(notice(:origin, @origin), web)

      web =
        origin_web(%{
          @finger => Net.redirect(moved),
          moved => jrd([link()], "https://elsewhere.example")
        })

      assert {:error, {:unlinked, :subject}} = verify(notice(:origin, @origin), web)
    end
  end

  describe "when the documents cannot be read, it is not 'unlinked'" do
    test "timeout, 5xx, 404, 410, 401, too large, not JSON" do
      n = notice(:inbox, "https://ops.example/inbox")

      for {answer, why} <- [
            {Net.down(), :unavailable},
            {Net.status(503), :unavailable},
            {Net.status(404), :gone},
            {Net.status(410), :gone},
            {Net.status(401), :unauthorized},
            {{:error, :document_too_large}, :too_large},
            {Net.json(%{}, type: "text/html"), :bad_document}
          ] do
        assert {:error, {:unreachable, ^why}} = verify(n, %{@controller => answer})
      end
    end
  end

  describe "evidence" do
    defp same_instant?(a, b), do: DateTime.compare(a, b) == :eq

    test "a confirmation is recorded; a failure after it records the attempt and keeps the confirmation" do
      n = notice(:inbox, "https://ops.example/users/ops/inbox")

      web = %{
        @controller => Net.json(actor(%{"inbox" => n.target})),
        n.target => Net.json(%{"id" => n.target, "inboxOf" => @controller})
      }

      assert :ok = verify(n, web, @now)

      assert {:ok, %{verified_at: v, attempted_at: a, failure: nil}} =
               Store.get_evidence(:inbox, n.target, @controller)

      assert same_instant?(v, @now) and same_instant?(a, @now)

      later = DateTime.add(@now, 3600, :second)

      assert {:error, {:unreachable, :unavailable}} =
               verify(n, %{@controller => Net.status(503)}, later)

      assert {:ok, %{verified_at: v, attempted_at: a, failure: :unavailable}} =
               Store.get_evidence(:inbox, n.target, @controller)

      assert same_instant?(v, @now) and same_instant?(a, later)
    end

    test "after a failure the same target is not asked again for a moment" do
      n = notice(:inbox, "https://ops.example/inbox")

      assert {:error, {:unreachable, :unavailable}} =
               verify(n, %{@controller => Net.status(503)}, @now)

      assert_received {:requested, @controller, _}

      soon = DateTime.add(@now, 5, :second)

      assert {:error, {:unreachable, :throttled}} =
               verify(n, %{@controller => Net.json(actor())}, soon)

      refute_received {:requested, _, _}

      later = DateTime.add(@now, 31, :second)

      assert {:error, {:unlinked, :not_the_actors_inbox}} =
               verify(n, %{@controller => Net.json(actor())}, later)
    end
  end
end
