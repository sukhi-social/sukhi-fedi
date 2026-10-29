# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Repo do
  use Ecto.Repo,
    otp_app: :sukhi_fedi,
    adapter: SukhiFedi.Store.Adapter
end
