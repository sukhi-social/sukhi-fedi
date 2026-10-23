# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule PullFederation.Etag do
  @moduledoc """
  The per-key token that stands for "the state of this actor's index
  right now".

  A token is 12 random bytes, drawn when the activity is appended and
  stored on that event. Nothing is derived from the sequence number, so
  there is no key to keep or rotate, a token says nothing about how many
  activities exist (a followers-only gap cannot leak), and it cannot be
  forged or predicted. The origin finds a returned token again by looking
  at the tokens of the events it still holds; it never decodes one.
  """

  @spec new() :: String.t()
  def new, do: :crypto.strong_rand_bytes(12) |> Base.url_encode64(padding: false)
end
