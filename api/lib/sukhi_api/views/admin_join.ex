# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiApi.Views.AdminJoin do
  @moduledoc """
  JSON shapes for the greeter's screen (docs/JOIN.md, step 2).

  What leaves is what is read: the receipt number, the three answers, when
  it came and the day it is to be looked at. The address goes out only in
  the one application the greeter opens (`render/1`), so a question can be
  asked from their own mail client before the answer; never in the list,
  and **never a hash**. It is erased with the words once the answer is sent.
  """

  @snippet_max 60

  @spec render_list([map()], map()) :: map()
  def render_list(apps, info) do
    %{
      applications: Enum.map(apps, &render_item/1),
      next_check: %{
        greeter: info.greeter,
        check_on: Date.to_iso8601(info.check_on),
        weekday: info.weekday,
        days_after: info.days_after
      }
    }
  end

  @spec render_item(map()) :: map()
  def render_item(app) do
    %{
      receipt: app.receipt,
      call_name: app.call_name,
      snippet: snippet(app),
      created_at: DateTime.to_iso8601(app.created_at),
      check_on: Date.to_iso8601(app.check_on)
    }
  end

  @spec render(map()) :: map()
  def render(app) do
    %{
      receipt: app.receipt,
      call_name: app.call_name,
      email: app.email,
      found: app.found,
      hope: app.hope,
      lang: app.lang,
      created_at: DateTime.to_iso8601(app.created_at),
      check_on: Date.to_iso8601(app.check_on)
    }
  end

  # The first thing they wrote, shortened, for the list.
  defp snippet(app) do
    case app.hope || app.found do
      nil ->
        nil

      text ->
        if String.length(text) > @snippet_max,
          do: String.slice(text, 0, @snippet_max) <> "…",
          else: text
    end
  end
end
