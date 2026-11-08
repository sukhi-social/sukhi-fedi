# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiShared.Keys do
  @moduledoc """
  The ids of an actor's keys, spelled in one place.

  The actor document publishes a key under an id, and every signature we make
  names that same id as its `keyId` / `verificationMethod`. If the two
  spellings ever drift, remote servers can no longer find the key that signed
  what they received. So the fragments (`#main-key`, `#ed25519-key`) are
  written here and nowhere else.

    * `main_key_id/1`    the RSA key: HTTP Signatures and the RsaSignature2017 LD-sig
    * `ed25519_key_id/1` the Ed25519 Multikey: FEP-8b32 Object Integrity Proofs
      (published as `assertionMethod`)
  """

  @spec main_key_id(String.t()) :: String.t()
  def main_key_id(actor_uri) when is_binary(actor_uri), do: actor_uri <> "#main-key"

  @spec ed25519_key_id(String.t()) :: String.t()
  def ed25519_key_id(actor_uri) when is_binary(actor_uri), do: actor_uri <> "#ed25519-key"
end
