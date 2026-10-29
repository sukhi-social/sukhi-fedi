# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Tokenizer.Whitespace do
  @moduledoc "No segmentation: the text as written (what Datalevin does by default)."

  @behaviour SukhiFedi.Tokenizer

  @impl true
  def segment(text, _opts), do: {:ok, segment!(text)}

  @spec segment!(String.t()) :: String.t()
  def segment!(text), do: text
end
