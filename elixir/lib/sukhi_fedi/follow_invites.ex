# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.FollowInvites do
  @moduledoc """
  Follow invites (FEP-bebd). A locked account's owner mints a code and
  shares the link; a Follow that arrives with that code as its
  `instrument` is accepted without waiting in the approval queue.

  The code is dereferenceable as an `InviteCode` object at
  `/users/<u>/invites/<code>`, so the invited party's server can show it
  and echo it back.
  """

  import Ecto.Query

  alias SukhiFedi.AP.ActorJson
  alias SukhiFedi.Repo
  alias SukhiFedi.Schema.{Account, FollowInvite}

  @spec mint(integer()) :: {:ok, FollowInvite.t()} | {:error, term()}
  def mint(account_id) when is_integer(account_id) do
    code = :crypto.strong_rand_bytes(12) |> Base.url_encode64(padding: false)

    %FollowInvite{account_id: account_id, code: code}
    |> Repo.insert()
  end

  @spec list(integer()) :: [FollowInvite.t()]
  def list(account_id) when is_integer(account_id) do
    Repo.all(
      from(i in FollowInvite,
        where: i.account_id == ^account_id,
        order_by: [desc: i.created_at]
      )
    )
  end

  @spec revoke(integer(), String.t()) :: {:ok, FollowInvite.t()} | {:error, :not_found}
  def revoke(account_id, code) when is_integer(account_id) do
    case Repo.get_by(FollowInvite, account_id: account_id, code: code) do
      nil -> {:error, :not_found}
      %FollowInvite{} = invite -> Repo.delete(invite)
    end
  end

  @doc "Look up a local account's invite by code, for the AP endpoint."
  @spec get(String.t(), String.t()) :: {:ok, FollowInvite.t()} | {:error, :not_found}
  def get(username, code) when is_binary(username) and is_binary(code) do
    with %Account{id: id} <- SukhiFedi.Accounts.by_local_username(username),
         %FollowInvite{} = invite <- Repo.get_by(FollowInvite, account_id: id, code: code) do
      {:ok, invite}
    else
      _ -> {:error, :not_found}
    end
  end

  @doc """
  FEP-bebd check: does the Follow's `instrument` name a live invite that
  belongs to `followee_id`? Only invites hosted on our own domain count.
  """
  @spec invited?(integer(), term()) :: boolean()
  def invited?(followee_id, instrument) when is_integer(followee_id) do
    case invite_code_from(instrument) do
      nil ->
        false

      code ->
        Repo.exists?(
          from(i in FollowInvite, where: i.account_id == ^followee_id and i.code == ^code)
        )
    end
  end

  @doc "The AP `InviteCode` object served at `/users/<u>/invites/<code>`."
  @spec invite_object(FollowInvite.t(), String.t()) :: map()
  def invite_object(%FollowInvite{code: code}, username) do
    actor_uri = ActorJson.actor_uri(username)

    %{
      "@context" => "https://www.w3.org/ns/activitystreams",
      "id" => "#{actor_uri}/invites/#{code}",
      "type" => "InviteCode",
      "attributedTo" => actor_uri
    }
  end

  # Pull the code out of an `instrument` (a URL string, or an object with
  # an `id`). Anything not matching our own invite URL shape yields nil.
  defp invite_code_from(instrument) when is_binary(instrument), do: code_from_uri(instrument)
  defp invite_code_from(%{"id" => id}) when is_binary(id), do: code_from_uri(id)
  defp invite_code_from(_), do: nil

  defp code_from_uri(uri) do
    domain = SukhiFedi.Config.domain!()

    case Regex.run(~r{^https?://#{Regex.escape(domain)}/users/[^/]+/invites/([^/]+)$}, uri) do
      [_, code] -> code
      _ -> nil
    end
  end
end
