defmodule SukhiDelivery.AP.ActorJson do
  @moduledoc """
  Person / Update(Person) JSON-LD for a local account. The shape lives in
  `SukhiShared.ActorJson` (one copy for the gateway and the delivery node);
  this module only supplies this node's domain.
  """

  alias SukhiDelivery.Schema.Account
  alias SukhiShared.ActorJson, as: Shared

  @spec actor_uri(Account.t() | String.t()) :: String.t()
  def actor_uri(account_or_username), do: Shared.actor_uri(SukhiDelivery.Config.domain!(), account_or_username)

  @spec profile_uri(Account.t() | String.t()) :: String.t()
  def profile_uri(account_or_username), do: Shared.profile_uri(SukhiDelivery.Config.domain!(), account_or_username)

  @spec build_person(Account.t()) :: map()
  def build_person(%Account{} = account), do: Shared.build_person(SukhiDelivery.Config.domain!(), account)

  @spec build_update(Account.t()) :: map()
  def build_update(%Account{} = account), do: Shared.build_update(SukhiDelivery.Config.domain!(), account)
end
