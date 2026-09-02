# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Integration.PasskeysTest do
  @moduledoc """
  Passkey register → login roundtrip against a synthetic P-256
  authenticator built right here in the test: real key pair, real
  CBOR, real ECDSA signatures — only the plastic is missing. What this
  exercises is our glue (challenge one-shot rows, credential storage,
  user-handle binding, clone counter), with Wax doing the same byte
  checks it would do for a browser.
  """

  use SukhiFedi.IntegrationCase, async: false

  @moduletag :integration

  alias SukhiFedi.Auth.Passkeys
  alias SukhiFedi.LocalAccounts

  # test env: DOMAIN defaults to localhost:4000
  @origin "http://localhost:4000"
  @rp_id "localhost"

  setup do
    n = System.unique_integer([:positive])
    {:ok, account} = LocalAccounts.create_admin("passkey_#{n}", "long-enough-pass")

    {pub, priv} = :crypto.generate_key(:ecdh, :prime256v1)
    <<4, x::binary-size(32), y::binary-size(32)>> = pub

    authenticator = %{
      priv: priv,
      cred_id: :crypto.strong_rand_bytes(16),
      cose: %{
        1 => 2,
        3 => -7,
        -1 => 1,
        -2 => %CBOR.Tag{tag: :bytes, value: x},
        -3 => %CBOR.Tag{tag: :bytes, value: y}
      }
    }

    %{account: account, authenticator: authenticator}
  end

  # ── synthetic authenticator ────────────────────────────────────────────

  defp b64(raw), do: Base.url_encode64(raw, padding: false)

  defp registration_response(auth, challenge_b64, sign_count) do
    cose_bin = CBOR.encode(auth.cose)

    auth_data =
      :crypto.hash(:sha256, @rp_id) <>
        <<0x45, sign_count::32>> <>
        <<0::128>> <> <<byte_size(auth.cred_id)::16>> <> auth.cred_id <> cose_bin

    attestation_object =
      CBOR.encode(%{
        "fmt" => "none",
        "attStmt" => %{},
        "authData" => %CBOR.Tag{tag: :bytes, value: auth_data}
      })

    client_data =
      JSON.encode!(%{type: "webauthn.create", challenge: challenge_b64, origin: @origin})

    %{
      "attestation_object" => b64(attestation_object),
      "client_data_json" => b64(client_data)
    }
  end

  defp assertion_response(auth, account, challenge_b64, sign_count) do
    auth_data = :crypto.hash(:sha256, @rp_id) <> <<0x05, sign_count::32>>

    client_data =
      JSON.encode!(%{type: "webauthn.get", challenge: challenge_b64, origin: @origin})

    message = auth_data <> :crypto.hash(:sha256, client_data)
    signature = :crypto.sign(:ecdsa, :sha256, message, [auth.priv, :prime256v1])

    %{
      "credential_id" => b64(auth.cred_id),
      "authenticator_data" => b64(auth_data),
      "signature" => b64(signature),
      "client_data_json" => b64(client_data),
      "user_handle" => b64(Integer.to_string(account.id))
    }
  end

  defp register(account, auth, sign_count \\ 0) do
    {ref, options} = Passkeys.register_options(account)

    response =
      auth
      |> registration_response(options.challenge, sign_count)
      |> Map.put("ref", ref)
      |> Map.put("nickname", "テストの鍵")

    Passkeys.register_finish(account, response)
  end

  # ── tests ──────────────────────────────────────────────────────────────

  test "register → login roundtrip", %{account: account, authenticator: auth} do
    assert {:ok, cred} = register(account, auth)
    assert cred.credential_id == b64(auth.cred_id)
    assert cred.nickname == "テストの鍵"

    {ref, options} = Passkeys.login_options()
    response = auth |> assertion_response(account, options.challenge, 1) |> Map.put("ref", ref)

    assert {:ok, found} = Passkeys.login_finish(response)
    assert found.id == account.id

    [stored] = Passkeys.list(account)
    assert stored.sign_count == 1
    assert %DateTime{} = stored.last_used_at
  end

  test "register options carry the user identity", %{account: account} do
    {_ref, options} = Passkeys.register_options(account)

    assert options.rp.id == @rp_id
    assert options.user.id == b64(Integer.to_string(account.id))
    assert options.user.name == account.username
    assert %{residentKey: "required"} = options.authenticatorSelection
  end

  test "a challenge ref is one-shot", %{account: account, authenticator: auth} do
    {ref, options} = Passkeys.register_options(account)

    response =
      auth |> registration_response(options.challenge, 0) |> Map.put("ref", ref)

    assert {:ok, _} = Passkeys.register_finish(account, response)
    assert {:error, :invalid_challenge} = Passkeys.register_finish(account, response)
  end

  test "someone else's register challenge is refused", %{account: account, authenticator: auth} do
    {:ok, other} =
      LocalAccounts.create_admin("passkey_o_#{System.unique_integer([:positive])}", "long-enough-pass")

    {ref, options} = Passkeys.register_options(other)
    response = auth |> registration_response(options.challenge, 0) |> Map.put("ref", ref)

    assert {:error, :invalid_challenge} = Passkeys.register_finish(account, response)
  end

  test "a tampered signature fails", %{account: account, authenticator: auth} do
    assert {:ok, _} = register(account, auth)

    {ref, options} = Passkeys.login_options()
    response = auth |> assertion_response(account, options.challenge, 1) |> Map.put("ref", ref)
    broken = Map.update!(response, "signature", fn _ -> b64(:crypto.strong_rand_bytes(70)) end)

    assert {:error, :verification_failed} = Passkeys.login_finish(broken)
  end

  test "a wrong user handle fails", %{account: account, authenticator: auth} do
    assert {:ok, _} = register(account, auth)

    {ref, options} = Passkeys.login_options()

    response =
      auth
      |> assertion_response(account, options.challenge, 1)
      |> Map.put("ref", ref)
      |> Map.put("user_handle", b64("999999"))

    assert {:error, :verification_failed} = Passkeys.login_finish(response)
  end

  test "a stale sign count is treated as a clone", %{account: account, authenticator: auth} do
    assert {:ok, _} = register(account, auth, 5)

    {ref, options} = Passkeys.login_options()
    response = auth |> assertion_response(account, options.challenge, 6) |> Map.put("ref", ref)
    assert {:ok, _} = Passkeys.login_finish(response)

    # same counter again — replayed/cloned hardware
    {ref2, options2} = Passkeys.login_options()
    response2 = auth |> assertion_response(account, options2.challenge, 6) |> Map.put("ref", ref2)
    assert {:error, :verification_failed} = Passkeys.login_finish(response2)
  end

  test "an unknown credential id fails without leaking", %{account: account, authenticator: auth} do
    assert {:ok, _} = register(account, auth)

    {ref, options} = Passkeys.login_options()

    response =
      auth
      |> assertion_response(account, options.challenge, 1)
      |> Map.put("ref", ref)
      |> Map.put("credential_id", b64(:crypto.strong_rand_bytes(16)))

    assert {:error, :unknown_credential} = Passkeys.login_finish(response)
  end

  test "delete removes the key and login stops working", %{account: account, authenticator: auth} do
    assert {:ok, cred} = register(account, auth)
    assert :ok = Passkeys.delete(account, cred.id)
    assert [] = Passkeys.list(account)
    assert {:error, :not_found} = Passkeys.delete(account, cred.id)

    {ref, options} = Passkeys.login_options()
    response = auth |> assertion_response(account, options.challenge, 1) |> Map.put("ref", ref)
    assert {:error, :unknown_credential} = Passkeys.login_finish(response)
  end

  test "rename changes only the label", %{account: account, authenticator: auth} do
    assert {:ok, cred} = register(account, auth)
    assert {:ok, renamed} = Passkeys.rename(account, cred.id, "  居間の iPad  ")
    assert renamed.nickname == "居間の iPad"
    assert renamed.credential_id == cred.credential_id
    assert renamed.sign_count == cred.sign_count

    # An empty label means "no label", not an empty string.
    assert {:ok, %{nickname: nil}} = Passkeys.rename(account, cred.id, "   ")

    assert {:error, :not_found} = Passkeys.rename(account, cred.id + 1, "x")

    {ref, options} = Passkeys.login_options()
    response = auth |> assertion_response(account, options.challenge, 1) |> Map.put("ref", ref)
    assert {:ok, _} = Passkeys.login_finish(response)
  end

  test "registering the same credential twice is refused", %{account: account, authenticator: auth} do
    assert {:ok, _} = register(account, auth)

    {ref, options} = Passkeys.register_options(account)
    response = auth |> registration_response(options.challenge, 0) |> Map.put("ref", ref)
    assert {:error, :already_registered} = Passkeys.register_finish(account, response)
  end
end
