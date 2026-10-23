# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule PullFederation.Visibility do
  @moduledoc """
  Which activities travel by pull and which stay push-only.

  Single predicate: both the origin (what gets a sequence number) and
  the stream (what gets sent) ask `pullable?/1`.
  """

  @pullable [:public, :unlisted, :followers]

  @spec pullable?(atom) :: boolean
  def pullable?(visibility), do: visibility in @pullable
end
