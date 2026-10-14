# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Markdown.Renderer.Elixir do
  @moduledoc "The renderer that runs today: Earmark."

  @behaviour SukhiFedi.Markdown.Renderer

  # gfm for the syntax people actually type; breaks so a newline is a newline.
  @opts %Earmark.Options{gfm: true, breaks: true}

  @impl true
  def render(text) when is_binary(text), do: Earmark.as_html!(text, @opts)
end
