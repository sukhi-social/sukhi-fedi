# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiDelivery.Keys do
  @moduledoc """
  The one place the delivery node reads our actors' private keys.

  Two things sign what leaves here, and they used to look the keys up on
  their own: the fan-out puts the keys into the payload (for the LD-sig and
  the FEP-8b32 proof), and the worker signs the HTTP request. Both ask here.

    * `payload_fields/1` — the signing fields to merge into a payload for a
      local actor: `privateKeyJwk` + `keyId`, and the Ed25519 pair when the
      actor has one. `%{}` for anything that is not one of our accounts.
    * `http_private_jwk/1` — the private JWK that signs a POST on behalf of
      `actor_uri`: an account's, or a 板's (`{slug}-deco`).

  The key ids are `SukhiShared.Keys`; how the keys are stored is this
  module's business (today: the owner's row), and the gateway's counterpart is
  `SukhiFedi.Keys`.
  """

  alias SukhiDelivery.{Accounts, Config}
  alias SukhiDelivery.Schema.Account
  alias SukhiShared.Keys, as: KeyIds

  @deco_suffix "-deco"

  @doc "The signing fields for a local account's `actor_uri` (`%{}` otherwise)."
  @spec payload_fields(String.t()) :: map()
  def payload_fields(actor_uri) when is_binary(actor_uri) do
    prefix = "https://#{Config.domain!()}/users/"

    if String.starts_with?(actor_uri, prefix) do
      username = String.replace_prefix(actor_uri, prefix, "")
      signing_fields(Accounts.by_local_username(username), actor_uri)
    else
      %{}
    end
  end

  def payload_fields(_), do: %{}

  @doc "Pure half of `payload_fields/1`: the fields an account's keys give."
  @spec signing_fields(Account.t() | nil, String.t()) :: map()
  def signing_fields(%Account{private_key_jwk: jwk} = account, actor_uri) when is_map(jwk) do
    %{privateKeyJwk: jwk, keyId: KeyIds.main_key_id(actor_uri)}
    |> put_ed25519(account, actor_uri)
  end

  def signing_fields(_account, _actor_uri), do: %{}

  # The Ed25519 key signs a FEP-8b32 Object Integrity Proof alongside the RSA
  # LD-sig. Its id must match the `assertionMethod` Multikey id the actor
  # document publishes, or receivers cannot resolve the proof.
  defp put_ed25519(fields, %Account{ed25519_private_key_jwk: jwk}, actor_uri) when is_map(jwk) do
    Map.merge(fields, %{
      ed25519PrivateKeyJwk: jwk,
      ed25519KeyId: KeyIds.ed25519_key_id(actor_uri)
    })
  end

  defp put_ed25519(fields, _account, _actor_uri), do: fields

  @doc "The private JWK that signs an HTTP request for `actor_uri`, or `nil`."
  @spec http_private_jwk(String.t() | nil) :: map() | nil
  def http_private_jwk(actor_uri) when is_binary(actor_uri) do
    username =
      actor_uri
      |> URI.parse()
      |> Map.get(:path, "")
      |> String.split("/")
      |> List.last()

    case Accounts.by_local_username(username) do
      %Account{private_key_jwk: jwk} when not is_nil(jwk) -> jwk
      # `{slug}-deco` は板の actor。鍵は accounts ではなく decos が
      # 自分で持っている ── 板の Announce は板自身が署名する。
      _ -> deco_private_key_jwk(username)
    end
  end

  def http_private_jwk(_), do: nil

  defp deco_private_key_jwk(username) do
    if String.ends_with?(username, @deco_suffix) do
      slug = String.trim_trailing(username, @deco_suffix)

      case SukhiDelivery.Repo.get_by(SukhiDelivery.Schema.Deco, slug: slug) do
        %{private_key_jwk: jwk} when not is_nil(jwk) -> jwk
        _ -> nil
      end
    end
  rescue
    # deco addon の無い鯖には decos 表が無い。
    _ -> nil
  end
end
