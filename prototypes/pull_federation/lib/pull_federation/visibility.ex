# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule PullFederation.Visibility do
  @moduledoc """
  Which activities travel by pull and which stay push-only.

  Single predicate: both the origin (what gets a sequence number) and
  the stream (what gets sent) ask `index/1`. Public and followers-only
  activities have separate sequences, so a follower-only gap never shows
  up in the public index.
  """

  @public [:public, :unlisted]

  @doc """
  Which sequence index an activity belongs to: `:public` (anything
  anyone can already read), `:followers`, or `nil` (push-only).
  """
  @spec index(atom) :: :public | :followers | nil
  def index(vis) when vis in @public, do: :public
  def index(:followers), do: :followers
  def index(_), do: nil

  @spec pullable?(atom) :: boolean
  def pullable?(visibility), do: index(visibility) != nil

  @doc "Wire key of an actor's sequence. The public index is the actor URI itself."
  @spec key(String.t(), :public | :followers) :: String.t()
  def key(actor, :public), do: actor
  def key(actor, :followers), do: actor <> "#followers"

  @doc "Inverse of `key/2`: the actor a sequence key belongs to."
  @spec actor_of(String.t()) :: String.t()
  def actor_of(key), do: String.replace_suffix(key, "#followers", "")
end
