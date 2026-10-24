# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiApi.Views.Timestamp do
  @moduledoc """
  Every view renders timestamps the same way: ISO 8601 for a `DateTime`,
  `nil` for anything else (an unset column, a not-yet-loaded field). One
  function, so the wire format of a date changes in one place.
  """

  @spec iso8601(term()) :: String.t() | nil
  def iso8601(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  def iso8601(_), do: nil
end
