# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Fedi.ServiceTest do
  use ExUnit.Case, async: true

  alias SukhiFedi.Fedi.Service
  alias SukhiFedi.FediGolden

  # The same payload the delivery node would send for a plain note.
  defp note_payload do
    %{
      "privateKeyJwk" => FediGolden.private_key_jwk(),
      "keyId" => FediGolden.key_id(),
      "actor" => FediGolden.actor(),
      "content" => "<p>hello</p>",
      "misskeyContent" => "hello",
      "recipientInboxes" => ["https://remote.test/inbox"],
      "noteId" => "https://sukhi.test/notes/1",
      "activityId" => "https://sukhi.test/notes/1/activity"
    }
  end

  describe "call/2 (what the gateway's FedifyClient uses)" do
    test "an unknown subject is an error string, not a crash" do
      assert Service.call("fedify.nope.v1", %{}) == {:error, "unknown subject: fedify.nope.v1"}
    end

    test "a malformed payload comes back as an error string" do
      assert {:error, msg} = Service.call("fedify.sign.v1", %{"inbox" => "https://x.test/inbox"})
      assert is_binary(msg)
    end

    test "atom-keyed input works: it is JSON-shaped before dispatch" do
      atom_keyed = for {k, v} <- note_payload(), into: %{}, do: {String.to_atom(k), v}

      assert {:ok, %{} = atom_result} =
               Service.call("fedify.translate.v1", %{object_type: "note", payload: atom_keyed})

      assert {:ok, %{} = string_result} =
               Service.call("fedify.translate.v1", %{
                 "object_type" => "note",
                 "payload" => note_payload()
               })

      assert Map.keys(atom_result) == Map.keys(string_result)
    end

    test "the result is JSON-shaped: string keys all the way down" do
      assert {:ok, result} =
               Service.call("fedify.translate.v1", %{
                 "object_type" => "note",
                 "payload" => note_payload()
               })

      assert result == result |> JSON.encode!() |> JSON.decode!()
    end

    test "gives what the NATS reply gives" do
      args = %{"object_type" => "note", "payload" => note_payload()}

      assert {:reply, reply} =
               Service.request(%{topic: "fedify.translate.v1", body: JSON.encode!(args)})

      assert {:ok, wire_data} = Service.call("fedify.translate.v1", args)
      assert %{"ok" => true, "data" => data} = JSON.decode!(reply)
      # Signatures carry a timestamp / nonce, so compare the shape, not the bytes.
      assert Map.keys(data) == Map.keys(wire_data)
    end
  end
end
