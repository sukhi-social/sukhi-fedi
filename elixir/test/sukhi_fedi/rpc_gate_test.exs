# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.RpcGateTest do
  use ExUnit.Case, async: true

  alias SukhiFedi.RpcGate
  alias SukhiFedi.Schema.{Account, Deco, OauthApp}

  @secrets %{
    private_key_jwk: %{"kty" => "RSA", "d" => "private"},
    ed25519_private_key_jwk: %{"kty" => "OKP", "d" => "private"},
    password_hash: "$argon2id$…",
    totp_secret: <<1, 2, 3>>,
    totp_last_used_step: 12_345
  }

  defp account(extra \\ %{}) do
    struct(
      Account,
      Map.merge(
        %{id: 7, username: "hinata", public_key_jwk: %{"kty" => "RSA", "n" => "public"}},
        Map.merge(@secrets, extra)
      )
    )
  end

  defp assert_blank(%Account{} = a) do
    for field <- RpcGate.secret_fields(), do: assert(Map.fetch!(a, field) == nil, "#{field} leaked")
  end

  describe "scrub/1" do
    test "blanks every secret field of an account and keeps the rest" do
      scrubbed = RpcGate.scrub(account())

      assert %Account{id: 7, username: "hinata", public_key_jwk: %{"n" => "public"}} = scrubbed
      assert_blank(scrubbed)
    end

    test "finds an account wherever it sits in the result" do
      {:ok, %{account: acct, app: app, scopes: scopes}} =
        RpcGate.scrub({:ok, %{account: account(), app: %OauthApp{id: 1, name: "x"}, scopes: ["read"]}})

      assert_blank(acct)
      assert %OauthApp{id: 1, name: "x"} = app
      assert scopes == ["read"]
    end

    test "a list of accounts, and an account in a tuple in a map" do
      assert [a, b] = RpcGate.scrub([account(), account(%{id: 8})])
      assert_blank(a)
      assert_blank(b)

      %{rows: [{c, 3}]} = RpcGate.scrub(%{rows: [{account(), 3}]})
      assert_blank(c)
    end

    test "any schema with these fields, not only Account (a Deco board's key)" do
      deco = RpcGate.scrub(struct(Deco, name: "board", private_key_jwk: %{"d" => "private"}))

      assert %Deco{name: "board", private_key_jwk: nil} = deco
    end

    test "plain maps with a secret key are blanked too, other keys kept" do
      assert RpcGate.scrub(%{private_key_jwk: %{"d" => "x"}, name: "n"}) ==
               %{private_key_jwk: nil, name: "n"}
    end

    test "opaque structs and plain values pass through untouched" do
      now = DateTime.utc_now()
      uri = URI.parse("https://example.test/x")

      assert RpcGate.scrub({:ok, now, uri, MapSet.new([1]), "s", 3, :a, nil}) ==
               {:ok, now, uri, MapSet.new([1]), "s", 3, :a, nil}
    end

    test "a loaded association is walked, an unloaded one is left as it is" do
      note_like = %{account: account(), others: %Ecto.Association.NotLoaded{__field__: :x}}

      %{account: acct, others: others} = RpcGate.scrub(note_like)

      assert_blank(acct)
      assert %Ecto.Association.NotLoaded{__field__: :x} = others
    end
  end

  describe "call/3" do
    test "runs the function and scrubs what it returns" do
      assert {:ok, %Account{username: "hinata"} = a} =
               RpcGate.call(__MODULE__, :returns_account, [])

      assert_blank(a)
    end

    test "an exception propagates, as it does on a plain :rpc.call" do
      assert_raise RuntimeError, "boom", fn -> RpcGate.call(__MODULE__, :raises, []) end
    end
  end

  def returns_account, do: {:ok, account()}
  def raises, do: raise("boom")
end
