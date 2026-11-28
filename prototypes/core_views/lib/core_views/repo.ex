# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule CoreViews.Repo do
  use Ecto.Repo, otp_app: :core_views, adapter: Ecto.Adapters.Hosi

  def views do
    [CoreViews.Note, CoreViews.Tombstone, CoreViews.Boost, CoreViews.Reaction, CoreViews.Follow]
  end
end
