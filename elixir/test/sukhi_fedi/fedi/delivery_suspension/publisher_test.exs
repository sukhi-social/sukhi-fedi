# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Fedi.DeliverySuspension.PublisherTest do
  # The telling side: what sukhi signs before its maintenance is what another
  # sukhi's Receiver takes (real `dtlv`), and the cancellation it holds back
  # ends it without being brought back by anything.
  use SukhiFedi.GraphCase

  alias SukhiFedi.Fedi.DeliverySuspension.{Control, Publisher, Receiver, Store}
  alias SukhiFedi.SuspensionNet, as: Net
  alias SukhiShared.DeliverySuspension.Notice
  alias SukhiShared.JWK

  @domain "rest.example"
  @origin "https://rest.example"
  @ops "https://rest.example/users/ops"
  @now ~U[2026-11-11 12:00:00Z]

  setup do
    {pub, priv} = :crypto.generate_key(:eddsa, :ed25519)

    jwk = %{
      "kty" => "OKP",
      "crv" => "Ed25519",
      "d" => Base.url_encode64(priv, padding: false),
      "x" => Base.url_encode64(pub, padding: false)
    }

    %{pub: pub, jwk: jwk, multibase: JWK.ed25519_multibase(pub)}
  end

  defp prepare(c, extra \\ []) do
    Publisher.prepare(
      Keyword.merge(
        [
          domain: @domain,
          controller: @ops,
          private_jwk: c.jwk,
          public_multibase: c.multibase,
          target: {:origin, @origin},
          expected_minutes: 60,
          now: @now,
          slug: "m1",
          summary: "Maintenance, about an hour.",
          url: "https://rest.example/status"
        ],
        extra
      )
    )
  end

  # a peer: another sukhi, which reads the key from the controller's actor
  defp peer(c, activity, at \\ @now) do
    fetch_key = fn key_id, _ ->
      {:ok,
       %{
         "id" => key_id,
         "type" => "Multikey",
         "controller" => @ops,
         "publicKeyMultibase" => c.multibase
       }}
    end

    Receiver.handle(activity,
      signer_host: @domain,
      now: at,
      fetch_key: fetch_key,
      control: fn _, _ -> :ok end
    )
  end

  describe "what is made" do
    test "a notice with room to spare, a held-back cancellation, a Create, an Undo", c do
      assert {:ok, made} = prepare(c)

      assert %{
               "type" => "DeliverySuspension",
               "attributedTo" => @ops,
               "targetOrigin" => @origin,
               "revision" => 1,
               "status" => "active",
               "announcement" => "https://rest.example/activities/suspension-m1-create",
               "summary" => "Maintenance, about an hour.",
               "proof" => %{"cryptosuite" => "eddsa-jcs-2022"}
             } = made.notice

      # 60 minutes asked, 1.5× the margin
      assert made.notice["endTime"] == "2026-11-11T13:30:00Z"
      assert %{"revision" => 2, "status" => "cancelled", "proof" => _} = made.cancel
      assert made.create["object"] == made.notice
      assert made.undo["object"] == made.create["id"]
      assert made.undo["type"] == "Undo"
    end

    test "the files: the notice and the control documents are public, the rest waits", c do
      {:ok, made} = prepare(c)

      assert Enum.sort(Map.keys(made.files)) == [
               "held/m1.cancel.json",
               "held/m1.undo.json",
               "public/control/.well-known/webfinger.json",
               "public/control/users/ops.json",
               "public/suspensions/m1.json",
               "send/m1.create.json"
             ]

      assert Jason.decode!(made.files["public/suspensions/m1.json"]) == made.notice
    end

    test "never longer than the policy allows", c do
      {:ok, made} = prepare(c, expected_minutes: 5000)
      assert made.ends_at == DateTime.add(@now, 48 * 3600, :second)
    end

    test "an inbox target, and a private operation is not a place for a long story", c do
      inbox = "https://rest.example/users/ops/inbox"
      assert {:ok, %{notice: %{"targetInbox" => ^inbox}}} = prepare(c, target: {:inbox, inbox})
      assert {:error, :summary_too_long} = prepare(c, summary: String.duplicate("あ", 201))
    end

    test "a key that is not the actor's is refused before anything is signed", c do
      {other, _} = :crypto.generate_key(:eddsa, :ed25519)

      assert {:error, :key_is_not_the_actors} =
               prepare(c, public_multibase: JWK.ed25519_multibase(other))
    end

    test "bad lengths", c do
      assert {:error, :bad_expected_minutes} = prepare(c, expected_minutes: 0)
    end
  end

  describe "another sukhi takes it" do
    test "the pre-signed Create is accepted, with the proof checked against the controller", c do
      {:ok, made} = prepare(c)
      assert {:ok, :accepted} = peer(c, made.create)

      assert {:ok, %{target: @origin, status: :active, accepted_at: %DateTime{}}, _} =
               Store.get_notice("https://rest.example/suspensions/m1")
    end

    test "a notice whose proof is by another key is not", c do
      {:ok, made} = prepare(c)
      {other, _} = :crypto.generate_key(:eddsa, :ed25519)
      forged = %{c | pub: other, multibase: JWK.ed25519_multibase(other)}
      assert {:error, :proof_failed} = peer(forged, made.create)
    end

    test "the held-back cancellation ends it, as an Update, whatever came first", c do
      {:ok, made} = prepare(c)
      assert {:ok, :accepted} = peer(c, made.create)

      cancel = Publisher.update_activity(made.cancel, @domain, slug: "m1")
      assert {:ok, :cancelled} = peer(c, cancel, DateTime.add(@now, 1800, :second))

      assert {:ok, %{status: :cancelled}, _} =
               Store.get_notice("https://rest.example/suspensions/m1")
    end

    test "the Undo ends it too; and the Create arriving after it does not bring it back", c do
      {:ok, made} = prepare(c)

      # the Undo is first (it is parked), then the Create it undoes
      assert :pass = peer(c, made.undo)
      assert {:ok, :cancelled} = peer(c, made.create)

      assert {:ok, %{status: :cancelled}, _} =
               Store.get_notice("https://rest.example/suspensions/m1")
    end

    test "after the cancellation, the same Create again does not revive it", c do
      {:ok, made} = prepare(c)
      assert {:ok, :accepted} = peer(c, made.create)
      assert {:ok, :cancelled} = peer(c, made.undo)

      assert {:error, :cancelled_is_final} = peer(c, made.create)

      assert {:ok, %{status: :cancelled}, _} =
               Store.get_notice("https://rest.example/suspensions/m1")
    end
  end

  describe "extending" do
    test "a higher revision, a later end; the pre-signed cancellation still ends it", c do
      {:ok, made} = prepare(c)
      assert {:ok, :accepted} = peer(c, made.create)

      later = DateTime.add(@now, 1800, :second)
      new_end = DateTime.add(@now, 4 * 3600, :second)

      assert {:ok, extended} =
               Publisher.extend(made.notice, new_end, private_jwk: c.jwk, now: later)

      assert extended["revision"] == 2
      assert extended["endTime"] == "2026-11-11T16:00:00Z"

      update = Publisher.update_activity(extended, @domain, slug: "m1")
      assert {:ok, :accepted} = peer(c, update, later)

      # the cancellation was made when the notice was at revision 1, and is still final
      assert {:ok, :cancelled} =
               peer(c, Publisher.update_activity(made.cancel, @domain, slug: "m1"), later)
    end

    test "not into the past, not beyond what a notice may last", c do
      {:ok, made} = prepare(c)
      opts = [private_jwk: c.jwk, now: DateTime.add(@now, 600, :second)]

      assert {:error, :end_in_the_past} = Publisher.extend(made.notice, @now, opts)

      too_far = DateTime.add(@now, 49 * 3600, :second)
      assert {:error, :longer_than_allowed} = Publisher.extend(made.notice, too_far, opts)
    end
  end

  describe "the control documents, answerable while the application sleeps" do
    # what the static files say, as the web a peer would read, checked by the
    # same `Control` that decides whether to believe a notice
    defp static_web(made) do
      base = "https://#{@domain}"

      # nginx ignores the query when it serves a file, so the answer is the same for any `resource`
      for {path, document} <- made.controls,
          url <- [base <> path, base <> path <> "?resource=" <> URI.encode_www_form(@origin)],
          into: %{} do
        {url, Net.json(document, type: "application/activity+json")}
      end
    end

    defp confirms(made, target_kind, target) do
      notice = %Notice{
        id: "https://rest.example/suspensions/m1",
        controller: @ops,
        target_kind: target_kind,
        target: target,
        revision: 1,
        published: @now
      }

      Control.verify(notice, @now, http: Net.http(static_web(made)))
    end

    test "an origin: WebFinger and the actor's controlledOrigin", c do
      {:ok, made} = prepare(c)
      assert :ok = confirms(made, :origin, @origin)
      assert Map.has_key?(made.controls, "/.well-known/webfinger")
    end

    test "a personal inbox: the actor's inbox, and inboxOf", c do
      inbox = "https://rest.example/users/ops/inbox"
      {:ok, made} = prepare(c, target: {:inbox, inbox})
      assert :ok = confirms(made, :inbox, inbox)
    end

    test "a shared inbox: sharedInbox, and deliveryController (not inboxOf)", c do
      shared = "https://rest.example/inbox"
      {:ok, made} = prepare(c, target: {:inbox, shared}, inbox_kind: :shared)
      assert :ok = confirms(made, :inbox, shared)
      assert made.controls["/inbox"]["deliveryController"] == @ops
      refute Map.has_key?(made.controls["/inbox"], "inboxOf")
    end

    test "they ride in the files, as static documents the notice's key is in", c do
      {:ok, made} = prepare(c)

      assert "public/control/users/ops.json" in Map.keys(made.files)
      assert "public/control/.well-known/webfinger.json" in Map.keys(made.files)

      actor = Jason.decode!(made.files["public/control/users/ops.json"])
      assert [%{"type" => "Multikey", "publicKeyMultibase" => mb}] = actor["assertionMethod"]
      assert mb == c.multibase
    end
  end
end
