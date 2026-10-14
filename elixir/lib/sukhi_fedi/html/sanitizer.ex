# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.HTML.Sanitizer do
  @moduledoc """
  What an HTML sanitiser has to do, so that it can be swapped.

  `sanitize/1` takes HTML text and returns HTML text containing only what
  `SukhiFedi.HTML.Policy` allows. It is a pure function of its argument: it
  must not read the database, the clock or the network, and must not raise on
  any valid UTF-8 string, however malformed the markup (it is untrusted input
  by definition). What it does with bytes that are not UTF-8 is not specified
  — the Elixir implementation raises — see docs/native-seams.md. The caller is `SukhiFedi.HTML.sanitize/1`, which handles
  non-binaries and the choice of implementation (`SukhiFedi.Backend`).

  Two implementations that answer differently are a bug in one of them, not
  a matter of taste: a post sanitised on write is read back by everyone.
  Run a new one as a shadow first.
  """

  @callback sanitize(html :: binary()) :: binary()
end
