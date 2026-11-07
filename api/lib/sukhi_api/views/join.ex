# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiApi.Views.Join do
  @moduledoc """
  JSON shapes for an application to join (docs/JOIN.md).

  What leaves is what the page needs: the words the person wrote, the
  receipt number, and the day it will be looked at. Never the address,
  never a hash.
  """

  @spec render_info(map()) :: map()
  def render_info(info) do
    %{
      greeter: info.greeter,
      check_on: Date.to_iso8601(info.check_on),
      weekday: info.weekday,
      days_after: info.days_after
    }
  end

  @spec render_applied(map(), String.t(), map()) :: map()
  def render_applied(app, claim, check) do
    %{
      receipt: app.receipt,
      claim: claim,
      check_on: Date.to_iso8601(app.check_on),
      weekday: check.weekday,
      days_after: check.days_after
    }
  end

  @spec render_application(map()) :: map()
  def render_application(app) do
    %{
      receipt: app.receipt,
      call_name: app.call_name,
      found: app.found,
      hope: app.hope,
      check_on: Date.to_iso8601(app.check_on)
    }
  end
end
