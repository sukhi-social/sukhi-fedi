# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule PullFederation.Etag do
  @moduledoc """
  The per-key token that stands for "the state of this actor's index
  right now".

  `token = base64url(first 12 bytes of HMAC-SHA256(secret, key ":" seq))`.

  Opaque on purpose: it reveals nothing about how many activities exist
  (a followers-only gap cannot leak), cannot be forged to point somewhere
  else, and the origin may change how it tracks state later. The origin
  finds a returned token again by looking at the tokens of the events it
  still holds, so it never has to decode one.
  """

  @spec token(binary, String.t(), pos_integer) :: String.t()
  def token(secret, key, seq) do
    :crypto.mac(:hmac, :sha256, secret, "#{key}:#{seq}")
    |> binary_part(0, 12)
    |> Base.url_encode64(padding: false)
  end
end
