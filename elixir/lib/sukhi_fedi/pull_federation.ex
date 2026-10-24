# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.PullFederation do
  @moduledoc """
  Pull Federation at the gateway: we are the *puller* of the hosts whose
  actors our users follow (`Notify` → `Puller` → `Pull`) and the *server of
  the log* for hosts that follow our actors (`Serve`, behind `Gate`). The
  origin half that writes the log and sends notifications lives on the
  delivery node. Spec: `docs/PULL_FEDERATION.md`.

  This module holds only the small things the parts share.
  """

  @doc """
  Where a host serves its log: the `pullStream` URL it published in its
  actor, or nil if it does not (any longer). The `:stream_base` config (a
  one-arity function) is a test seam so a local server can stand in for a
  peer — nothing sets it in production.
  """
  @spec stream_base(String.t()) :: String.t() | nil
  def stream_base(host) do
    case Application.get_env(:sukhi_fedi, :pull_federation, []) |> Keyword.get(:stream_base) do
      fun when is_function(fun, 1) -> fun.(host)
      _ -> with %{stream: url} <- SukhiShared.PeerCapabilities.endpoints(SukhiFedi.Repo, host), do: url
    end
  end
end
