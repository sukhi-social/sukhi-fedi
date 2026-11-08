# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Fedi.DeliverySuspension.ReceiverTest do
  # Real `dtlv` (GraphCase): the store is part of what is under test.
  use SukhiFedi.GraphCase

  alias SukhiFedi.Fedi.Oip
  alias SukhiShared.JWK
  alias SukhiFedi.Fedi.DeliverySuspension.{Receiver, Store}
  alias SukhiShared.DeliverySuspension.{Gate, Policy}

  @alice "https://a.example/users/alice"
  @mallory "https://m.example/users/mallory"
  @notice_id "https://a.example/suspensions/1"
  @create_id "https://a.example/activities/c1"
  @now ~U[2026-11-06 12:00:00Z]

  defp iso(dt), do: DateTime.to_iso8601(dt)
  defp ago(seconds), do: DateTime.add(@now, -seconds, :second)
  defp ahead(seconds), do: DateTime.add(@now, seconds, :second)

  defp notice(attrs \\ %{}) do
    Map.merge(
      %{
        "id" => @notice_id,
        "type" => "DeliverySuspension",
        "attributedTo" => @alice,
        "targetInbox" => "https://b.example/inbox",
        "revision" => 1,
        "published" => iso(ago(60)),
        "endTime" => iso(ahead(3600))
      },
      attrs
    )
  end

  defp create(object \\ notice(), id \\ @create_id),
    do: %{"id" => id, "type" => "Create", "actor" => @alice, "object" => object}

  defp update(object, id),
    do: %{"id" => id, "type" => "Update", "actor" => @alice, "object" => object}

  defp undo(create_or_id, id \\ "https://a.example/activities/u1"),
    do: %{"id" => id, "type" => "Undo", "actor" => @alice, "object" => create_or_id}

  defp recv(activity, extra \\ []) do
    Receiver.handle(
      activity,
      Keyword.merge([signer_host: "a.example", now: @now, control: fn _, _ -> :ok end], extra)
    )
  end

  defp held(id \\ @notice_id) do
    {:ok, notice, create_id} = Store.get_notice(id)
    {notice, create_id}
  end

  describe "taking a notice" do
    test "a Create is stored, and starts when we took it if it says nothing" do
      assert {:ok, :accepted} = recv(create())

      {notice, create_id} = held()
      assert create_id == @create_id
      assert notice.status == :active
      assert notice.target == "https://b.example/inbox"
      assert notice.accepted_at == @now
      assert notice.effective_start == @now
    end

    test "an explicit startTime is the start" do
      start = ago(30)
      assert {:ok, :accepted} = recv(create(notice(%{"startTime" => iso(start)})))
      assert {%{effective_start: ^start}, _} = held()
    end

    test "what is stored is what the gate reads, and reads back the same after a restart" do
      assert {:ok, :accepted} = recv(create())
      {:ok, before} = Store.all_notices()
      policy = Policy.default()

      assert Gate.suspended?("https://b.example/inbox", @now, before, policy)
      refute Gate.suspended?("https://c.example/inbox", @now, before, policy)

      # the dtlv child dies and the supervisor reopens the same directory
      pid = Process.whereis(Graph.client())
      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, _, _, _}
      wait_for_client(pid)

      assert {:ok, ^before} = Store.all_notices()
    end

    test "a notice that is not about suspension is not ours" do
      note = %{"id" => "https://a.example/n/1", "type" => "Note", "content" => "hi"}
      assert :pass = recv(create(note, "https://a.example/activities/n1"))

      assert :pass =
               recv(%{"type" => "Follow", "actor" => @alice, "object" => "https://b.example/u"})
    end

    test "control is asked for a new notice, and a refusal stores nothing" do
      assert {:error, :nope} = recv(create(), control: fn _, _ -> {:error, :nope} end)
      assert :none = Store.get_notice(@notice_id)
    end
  end

  describe "with the real control check (the web is stood in for)" do
    alias SukhiFedi.Fedi.DeliverySuspension.Control
    alias SukhiFedi.SuspensionNet, as: Net

    @inbox "https://a.example/users/alice/inbox"

    defp linked_web do
      %{
        @alice => Net.json(%{"id" => @alice, "inbox" => @inbox}),
        @inbox => Net.json(%{"id" => @inbox, "inboxOf" => @alice})
      }
    end

    defp checked(web),
      do: [control: fn n, now -> Control.verify(n, now, http: Net.http(web)) end]

    defp about_inbox(extra \\ %{}), do: notice(Map.merge(%{"targetInbox" => @inbox}, extra))

    test "a notice the controller really stands behind is taken, and the evidence is kept" do
      assert {:ok, :accepted} = recv(create(about_inbox()), checked(linked_web()))

      assert {:ok, %{verified_at: %DateTime{}, failure: nil}} =
               Store.get_evidence(:inbox, @inbox, @alice)
    end

    test "a notice the target does not point back to is refused, and nothing is stored" do
      web = %{linked_web() | @inbox => Net.json(%{"id" => @inbox})}

      assert {:error, {:unlinked, :inbox_of}} = recv(create(about_inbox()), checked(web))
      assert :none = Store.get_notice(@notice_id)
    end

    test "documents that cannot be read are not a reason to take a notice" do
      web = %{@alice => Net.status(503)}

      assert {:error, {:unreachable, :unavailable}} = recv(create(about_inbox()), checked(web))
      assert :none = Store.get_notice(@notice_id)
    end

    test "a notice already taken can still be cancelled while the controller is unreachable" do
      assert {:ok, :accepted} = recv(create(about_inbox()), checked(linked_web()))
      cancel = about_inbox(%{"revision" => 2, "status" => "cancelled"})

      assert {:ok, _} =
               recv(update(cancel, "https://a.example/activities/u2"), checked(%{}))

      assert {%{status: :cancelled}, _} = held()
    end
  end

  describe "who is speaking" do
    test "the signature host must be the actor's host" do
      assert {:error, :signer_mismatch} = recv(create(), signer_host: "evil.example")
      assert {:error, :unauthenticated} = recv(create(), signer_host: nil)
      assert :none = Store.get_notice(@notice_id)
    end

    test "the activity id and the notice id are the controller's own" do
      assert {:error, :bad_activity_id} = recv(create(notice(), "https://evil.example/a/1"))

      assert {:error, {:form, :id_not_owned}} =
               recv(create(notice(%{"id" => "https://evil.example/suspensions/1"})))
    end

    test "the notice's controller is the actor" do
      forged = notice(%{"attributedTo" => "https://a.example/users/bob"})
      assert {:error, :controller_is_not_actor} = recv(create(forged))
    end
  end

  describe "the notice's own proof is checked against attributedTo" do
    setup do
      {pub, priv} = :crypto.generate_key(:eddsa, :ed25519)
      %{pub: pub, priv: priv}
    end

    defp fetch_key(pub, controller) do
      fn key_id, _opts ->
        {:ok,
         %{
           "id" => key_id,
           "type" => "Multikey",
           "controller" => controller,
           "publicKeyMultibase" => JWK.ed25519_multibase(pub)
         }}
      end
    end

    test "a proof by the controller's key is accepted, and its expiry bounds the notice", c do
      {:ok, signed} = Oip.sign(notice(), c.priv, @alice <> "#key-1", created: iso(ago(30)))
      expires = ahead(600)
      signed = put_in(signed, ["proof", "expires"], iso(expires))
      # `expires` is not part of the signed config here; the point is that it is read
      assert {:ok, :accepted} = recv(create(signed), fetch_key: fetch_key(c.pub, @alice))
      assert {%{proof_expires_at: ^expires}, _} = held()
    end

    test "a valid proof by somebody else's key is refused", c do
      {:ok, signed} = Oip.sign(notice(), c.priv, @mallory <> "#key-1", created: iso(ago(30)))

      assert {:error, :proof_failed} =
               recv(create(signed), fetch_key: fetch_key(c.pub, @mallory))

      assert :none = Store.get_notice(@notice_id)
    end

    test "a proof that does not match the document is refused", c do
      {:ok, signed} = Oip.sign(notice(), c.priv, @alice <> "#key-1", created: iso(ago(30)))
      tampered = Map.put(signed, "targetInbox", "https://victim.example/inbox")

      assert {:error, :proof_failed} =
               recv(create(tampered), fetch_key: fetch_key(c.pub, @alice))
    end
  end

  describe "form, size and age" do
    test "a bad form is refused with the reason" do
      assert {:error, {:form, :two_targets}} =
               recv(create(notice(%{"targetOrigin" => "https://b.example"})))
    end

    test "a body over the limit is refused" do
      assert {:error, :too_large} = recv(create(), raw_body: String.duplicate("x", 64 * 1024 + 1))
    end

    test "published in the future, or older than the limit, is refused" do
      assert {:error, :from_the_future} =
               recv(create(notice(%{"published" => iso(ahead(3600))})))

      assert {:error, :too_old} =
               recv(create(notice(%{"published" => iso(ago(15 * 86_400))})))
    end

    test "the activity's own published is held to the same limits" do
      activity = Map.put(create(), "published", iso(ahead(3600)))
      assert {:error, :from_the_future} = recv(activity)
    end

    test "one controller may keep only so many" do
      policy = %Policy{max_notices_per_controller: 1}
      assert {:ok, :accepted} = recv(create(), policy: policy)

      second = notice(%{"id" => "https://a.example/suspensions/2"})

      assert {:error, :too_many_notices} =
               recv(create(second, "https://a.example/activities/c2"), policy: policy)
    end
  end

  describe "revisions" do
    setup do
      {:ok, :accepted} = recv(create())
      :ok
    end

    test "the same revision with the same content does nothing, even re-signed" do
      assert {:ok, :unchanged} = recv(update(notice(), "https://a.example/activities/u2"))

      resigned =
        Map.put(notice(), "proof", %{"type" => "DataIntegrityProof", "cryptosuite" => "x"})

      assert {:ok, :unchanged} = recv(update(resigned, "https://a.example/activities/u3"))
    end

    test "the same revision with other content is refused" do
      other = notice(%{"summary" => "something else"})

      assert {:error, :same_revision_different_content} =
               recv(update(other, "https://a.example/activities/u2"))

      assert {%{summary: nil}, _} = held()
    end

    test "a lower revision does not replace, a higher one does" do
      assert {:ok, :accepted} =
               recv(
                 update(notice(%{"revision" => 5, "summary" => "five"}), "https://a.example/a/5")
               )

      assert {:ok, :stale} =
               recv(
                 update(notice(%{"revision" => 3, "summary" => "three"}), "https://a.example/a/3")
               )

      assert {%{revision: 5, summary: "five"}, @create_id} = held()
    end

    test "the members a revision may not change are refused" do
      for changed <- [
            %{"targetInbox" => "https://c.example/inbox"},
            %{"published" => iso(ago(30))},
            %{"announcement" => "https://a.example/activities/c1"}
          ] do
        assert {:error, :immutable_changed} =
                 recv(update(notice(Map.put(changed, "revision", 2)), "https://a.example/a/x"))
      end
    end

    test "a revision that extends is checked again, one that shortens is not" do
      ask = fn _, _ ->
        send(self(), :asked)
        :ok
      end

      longer = notice(%{"revision" => 2, "endTime" => iso(ahead(7200))})
      assert {:ok, :accepted} = recv(update(longer, "https://a.example/a/2"), control: ask)
      assert_received :asked

      refuse = fn _, _ -> {:error, :stale_evidence} end
      shorter = notice(%{"revision" => 3, "endTime" => iso(ahead(600))})
      assert {:ok, :accepted} = recv(update(shorter, "https://a.example/a/3"), control: refuse)

      longer_again = notice(%{"revision" => 4, "endTime" => iso(ahead(7200))})

      assert {:error, :stale_evidence} =
               recv(update(longer_again, "https://a.example/a/4"), control: refuse)

      assert {%{revision: 3}, _} = held()
    end

    test "when it started does not move because a later revision has no startTime" do
      {first, _} = held()
      later = DateTime.add(@now, 120, :second)

      assert {:ok, :accepted} =
               recv(update(notice(%{"revision" => 2, "summary" => "x"}), "https://a.example/a/2"),
                 now: later
               )

      assert {%{effective_start: start}, _} = held()
      assert start == first.effective_start
    end
  end

  describe "cancellation is final" do
    setup do
      {:ok, :accepted} = recv(create())
      :ok
    end

    defp assert_dead do
      assert {%{status: :cancelled}, _} = held()
      {:ok, notices} = Store.all_notices()
      refute Gate.suspended?("https://b.example/inbox", @now, notices, Policy.default())
    end

    test "an Update with status cancelled ends it, whatever its revision, with no re-check" do
      refuse = fn _, _ -> {:error, :never_asked} end
      cancelled = notice(%{"revision" => 1, "status" => "cancelled"})

      assert {:ok, :cancelled} = recv(update(cancelled, "https://a.example/a/2"), control: refuse)
      assert_dead()
    end

    test "an Undo that carries the Create ends it" do
      assert {:ok, :cancelled} =
               recv(undo(create()), control: fn _, _ -> {:error, :never_asked} end)

      assert_dead()
    end

    test "an Undo that names the Create by id ends it" do
      assert {:ok, :cancelled} =
               recv(undo(@create_id), control: fn _, _ -> {:error, :never_asked} end)

      assert_dead()
    end

    test "a higher revision after the cancellation does not bring it back" do
      assert {:ok, :cancelled} = recv(undo(@create_id))

      assert {:error, :cancelled_is_final} =
               recv(update(notice(%{"revision" => 9}), "https://a.example/a/9"))

      assert_dead()
    end

    test "fetching the active notice again after the cancellation does not bring it back" do
      assert {:ok, :cancelled} = recv(undo(@create_id))
      assert {:error, :cancelled_is_final} = recv(create())
      assert_dead()
    end

    test "cancelling twice is quiet" do
      assert {:ok, :cancelled} = recv(undo(@create_id))
      assert {:ok, :unchanged} = recv(undo(@create_id, "https://a.example/activities/u2"))
    end

    test "somebody else cannot cancel it" do
      other = %{undo(@create_id) | "actor" => "https://m.example/users/mallory"}
      assert :pass = recv(other, signer_host: "m.example")
      assert {%{status: :active}, _} = held()
    end
  end

  describe "an Undo that comes first" do
    test "is held, is not answered, and is applied before the Create takes effect" do
      assert :pass = recv(undo(@create_id))
      assert Store.pending?(@alice, @create_id, @now)
      assert :none = Store.get_notice(@notice_id)

      assert {:ok, :cancelled} = recv(create())
      assert_dead_now()
      refute Store.pending?(@alice, @create_id, @now)

      assert {:error, :cancelled_is_final} =
               recv(update(notice(%{"revision" => 4}), "https://a.example/a/4"))
    end

    defp assert_dead_now do
      assert {%{status: :cancelled}, @create_id} = held()
      {:ok, notices} = Store.all_notices()
      refute Gate.suspended?("https://b.example/inbox", @now, notices, Policy.default())
    end

    test "holding only changes the policy of the Create that matches, and is capped" do
      policy = %Policy{max_pending_per_actor: 2}

      for n <- 1..4 do
        assert :pass = recv(undo("https://a.example/activities/c#{n}0"), policy: policy)
      end

      held_count =
        for n <- 1..4, Store.pending?(@alice, "https://a.example/activities/c#{n}0", @now), do: n

      assert length(held_count) == 2
    end

    test "an unauthenticated one is not held" do
      assert :pass = recv(undo(@create_id), signer_host: "evil.example")
      refute Store.pending?(@alice, @create_id, @now)
    end

    test "an id on another origin is not held" do
      other = "https://evil.example/activities/c1"
      assert :pass = recv(undo(other))
      refute Store.pending?(@alice, other, @now)
    end
  end

  describe "forgetting" do
    test "a forgotten notice moves the cutoff, so it cannot come back when the limit is loosened" do
      assert {:ok, :accepted} = recv(create())
      published = DateTime.add(@now, -60, :second)

      later = DateTime.add(@now, 15 * 86_400, :second)
      assert %{notices: 1} = Store.sweep(later, Policy.default())
      assert :none = Store.get_notice(@notice_id)

      assert DateTime.compare(Store.cutoff(@alice), DateTime.add(published, 1, :microsecond)) ==
               :eq

      loosened = %Policy{notice_max_age: 60 * 86_400}
      assert {:error, :before_cutoff} = recv(create(), now: later, policy: loosened)
    end

    test "held Undos expire" do
      assert :pass = recv(undo(@create_id))
      later = DateTime.add(@now, 15 * 86_400, :second)
      assert %{pending: 1} = Store.sweep(later, Policy.default())
      refute Store.pending?(@alice, @create_id, later)
    end

    test "the cutoff only moves forward" do
      :ok = Store.advance_cutoff(@alice, @now)
      :ok = Store.advance_cutoff(@alice, ago(100))
      assert DateTime.compare(Store.cutoff(@alice), @now) == :eq
    end
  end

  describe "telemetry" do
    test "a refusal names its reason, an acceptance its outcome" do
      {:ok, _} = Application.ensure_all_started(:telemetry)
      id = "delivery-suspension-test-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        id,
        [:sukhi_fedi, :delivery_suspension, :received],
        &__MODULE__.forward/4,
        self()
      )

      on_exit(fn -> :telemetry.detach(id) end)

      recv(create(), signer_host: "evil.example")
      assert_receive {:telemetry, %{status: :rejected, detail: :signer_mismatch, type: "Create"}}

      recv(create())
      assert_receive {:telemetry, %{status: :ok, detail: :accepted}}
    end
  end

  @doc false
  def forward(_event, _measure, meta, parent), do: send(parent, {:telemetry, meta})

  # the supervisor restarts the child under the same name
  defp wait_for_client(old_pid, tries \\ 100) do
    case Process.whereis(Graph.client()) do
      pid when is_pid(pid) and pid != old_pid ->
        :ok

      _ when tries > 0 ->
        Process.sleep(100)
        wait_for_client(old_pid, tries - 1)

      _ ->
        flunk("graph client did not come back")
    end
  end
end
