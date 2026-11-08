# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Config do
  @moduledoc false

  @spec domain!() :: String.t()
  def domain!, do: Application.fetch_env!(:sukhi_fedi, :domain)

  @doc """
  The `Domain=` for the login cookies, so a session minted at
  `natadeco.com` is also sent to `travel.natadeco.com`: the public host
  with a leading dot, port dropped. `nil` (host-only cookie) for a bare
  hostname like `localhost` — browsers refuse a Domain with no dot.

  `api` carries the same rule in its own `Config` (separate deployable).
  """
  @spec cookie_domain() :: String.t() | nil
  def cookie_domain do
    host = domain!() |> String.split(":", parts: 2) |> hd()
    if String.contains?(host, "."), do: "." <> host, else: nil
  end

  @doc """
  Whether this node talks to NATS (`NATS_ENABLED`, default on).

  Off is for the single-BEAM `combined` release, where nothing needs NATS
  for the core: the delivery side calls `Fedi.Service` in-process, and a new
  post reaches the streaming feeds by a direct call. What does stop working
  without NATS: the WebTransport edge (it reads `stream.*` from NATS), and
  any gateway/delivery pair that runs in separate BEAMs.
  """
  @spec nats_enabled?() :: boolean()
  def nats_enabled?,
    do: Application.get_env(:sukhi_fedi, :nats, []) |> Keyword.get(:enabled, true)

  @doc """
  Whether signup needs an invite code (`INVITE_REQUIRED`, default on).

  The one definition of "is the door latched" — signup reads it, and
  `/api/v1,v2/instance` reports it so a client can stop asking for a
  code that is not wanted. Two literals drift, and the drift here is a
  required field nobody can fill.
  """
  @spec invite_required?() :: boolean()
  def invite_required?, do: Application.get_env(:sukhi_fedi, :invite_required, true)

  @doc """
  The local username `INSTANCE_CONTACT` names as the server's contact, or
  `nil` to let `Accounts.site_contact/0` fall back to the oldest admin.
  """
  @spec instance_contact() :: String.t() | nil
  def instance_contact do
    case Application.get_env(:sukhi_fedi, :instance_contact) do
      name when is_binary(name) and name != "" -> String.trim_leading(name, "@")
      _ -> nil
    end
  end
end
