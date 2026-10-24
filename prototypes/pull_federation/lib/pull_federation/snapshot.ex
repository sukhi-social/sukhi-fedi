# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule PullFederation.Snapshot do
  @moduledoc """
  Where the public sequence snapshots live: the sccache layout, first two
  hex characters / next two / full hash.

      <base>/ab/cd/<sha256(actor uri) in hex>     one actor's public seq
      <base>/ab/_index                            bucket `ab`: every actor in it

  Both sides compute the path from the actor URI alone, so a notification
  never has to carry a location. Only the **public** index goes into
  snapshots: they are plain cacheable GETs for anyone. The followers-only
  index never does; it travels inline, to the followers' domains only.
  """

  alias PullFederation.Visibility

  @spec hash(String.t()) :: String.t()
  def hash(actor), do: :crypto.hash(:sha256, actor) |> Base.encode16(case: :lower)

  @doc "Bucket = first two hex characters (256 of them)."
  @spec bucket(String.t()) :: String.t()
  def bucket(actor), do: binary_part(hash(actor), 0, 2)

  @spec path(String.t()) :: String.t()
  def path(actor) do
    <<a::binary-size(2), b::binary-size(2), _::binary>> = h = hash(actor)
    "#{a}/#{b}/#{h}"
  end

  @spec bucket_path(String.t()) :: String.t()
  def bucket_path(bucket), do: "#{bucket}/_index"

  @doc "Snapshots exist for public keys only."
  @spec public_key?(String.t()) :: boolean
  def public_key?(key), do: Visibility.actor_of(key) == key
end
