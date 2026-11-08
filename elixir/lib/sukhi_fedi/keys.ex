# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Keys do
  @moduledoc """
  The one door to the keys our own actors sign with.

  A local actor (an account, a bot, a 板) holds an RSA pair for HTTP Signatures
  and the LD-sig, and an Ed25519 pair for FEP-8b32 proofs. Before this module
  five places made a pair and spread its five fields into a row, and two
  places read the private half back and spelled the `keyId`. Now:

    * `new_attrs/0` — a fresh pair, as the five key columns a new owner is
      inserted with. Nothing else generates keys.
    * `identity/2` — what a signed fetch needs from an account:
      `%{keyId, privateJwk, publicJwk}`.

  The key ids themselves (`#main-key`, `#ed25519-key`) are `SukhiShared.Keys`.

  Where the keys live is decided *here*, not by the callers: today they are
  columns of the owner's row; when the store changes, only this module (and
  the delivery node's `SukhiDelivery.Keys`, which reads them back) moves.
  The private halves are secret fields: `SukhiFedi.RpcGate` blanks them
  before anything leaves the node.
  """

  alias SukhiFedi.Addons.NodeinfoMonitor.KeyGen
  alias SukhiFedi.Schema.Account

  @type attrs :: %{
          public_key_pem: String.t(),
          public_key_jwk: map(),
          private_key_jwk: map(),
          ed25519_private_key_jwk: map(),
          ed25519_public_multibase: String.t()
        }

  @doc "A fresh RSA + Ed25519 pair, as the key columns of a new owner's row."
  @spec new_attrs() :: attrs()
  def new_attrs do
    keys = KeyGen.generate()

    %{
      public_key_pem: keys.public_pem,
      public_key_jwk: keys.public_jwk,
      private_key_jwk: keys.private_jwk,
      ed25519_private_key_jwk: keys.ed25519_private_jwk,
      ed25519_public_multibase: keys.ed25519_public_multibase
    }
  end

  @doc """
  The signing identity of a local account on `domain`, for an authorized
  (signed) fetch. `nil` when the account has no private key.
  """
  @spec identity(Account.t() | nil, String.t()) ::
          %{keyId: String.t(), privateJwk: map(), publicJwk: map() | nil} | nil
  def identity(%Account{username: username, private_key_jwk: priv, public_key_jwk: pub}, domain)
      when is_map(priv) and is_binary(domain) do
    %{
      keyId: SukhiShared.Keys.main_key_id("https://#{domain}/users/#{username}"),
      privateJwk: priv,
      publicJwk: pub
    }
  end

  def identity(_account, _domain), do: nil
end
