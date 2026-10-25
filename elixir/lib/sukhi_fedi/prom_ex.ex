# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.PromEx do
  use PromEx, otp_app: :sukhi_fedi

  @impl true
  def plugins do
    [
      PromEx.Plugins.Application,
      PromEx.Plugins.Beam,
      {PromEx.Plugins.Ecto, otp_app: :sukhi_fedi, repos: [SukhiFedi.Repo]},
      {PromEx.Plugins.Oban, queue_poll_rate: 5_000},
      SukhiFedi.PromEx.Load
    ]
  end
end
