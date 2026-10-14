# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Markdown.Renderer do
  @moduledoc """
  Markdown text → HTML, and only that: GitHub-flavoured, a bare newline is a
  `<br>`. What it returns is **not safe** — a line that starts a block of raw
  HTML comes out as that HTML (`<script>` included). That is by design and
  the reason `SukhiFedi.Markdown.to_html/2`, the only caller, always sanitises
  what follows; do not call an implementation directly.

  A pure function of its argument, no raise on any valid UTF-8 string.
  """

  @callback render(markdown :: binary()) :: html :: binary()
end
