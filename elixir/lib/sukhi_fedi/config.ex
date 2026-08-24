# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Config do
  @moduledoc false

  @spec domain!() :: String.t()
  def domain!, do: Application.fetch_env!(:sukhi_fedi, :domain)

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
