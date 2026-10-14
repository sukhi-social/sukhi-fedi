# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.HTML.Sanitizer.Elixir do
  @moduledoc """
  The sanitiser that runs today: `html_sanitize_ex` (mochiweb's parser) with a
  scrubber generated from `SukhiFedi.HTML.Policy`.
  """

  @behaviour SukhiFedi.HTML.Sanitizer

  @impl true
  def sanitize(html) when is_binary(html) do
    HtmlSanitizeEx.Scrubber.scrub(html, SukhiFedi.HTML.Sanitizer.Elixir.Scrubber)
  end
end

defmodule SukhiFedi.HTML.Sanitizer.Elixir.Scrubber do
  @moduledoc false
  # The `allow_tag_*` macros take their arguments as literal syntax, so the
  # table is spliced in through `Code.eval_quoted/3` rather than written out:
  # the policy stays one piece of data, and this module only turns it into
  # function clauses.
  use HtmlSanitizeEx

  for {tag, spec} <- SukhiFedi.HTML.Policy.tags() do
    for {attr, schemes} <- Map.get(spec, :uri, %{}) do
      Code.eval_quoted(
        quote(do: allow_tag_with_uri_attributes(unquote(tag), [unquote(attr)], unquote(schemes))),
        [],
        __ENV__
      )
    end

    Code.eval_quoted(
      quote(do: allow_tag_with_these_attributes(unquote(tag), unquote(spec.attrs))),
      [],
      __ENV__
    )
  end
end
