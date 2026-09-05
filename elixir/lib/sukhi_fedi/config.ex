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
  Whether signup needs an invite code (`INVITE_REQUIRED`, default on).

  The one definition of "is the door latched" — signup reads it, and
  `/api/v1,v2/instance` reports it so a client can stop asking for a
  code that is not wanted. Two literals drift, and the drift here is a
  required field nobody can fill.
  """
  @spec invite_required?() :: boolean()
  def invite_required?, do: Application.get_env(:sukhi_fedi, :invite_required, true)
end
