# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Tokenizer do
  @moduledoc """
  Word segmentation for full-text search.

  Datalevin's full-text index splits on spaces, so Japanese (no spaces) is
  not found by word. The text is segmented *here* and the space-separated
  result is stored in `<ns>/tokens`; the original text is untouched. The
  query string goes through the same `segment/2`: indexing and querying must
  use the one tokenizer, or nothing matches.

  The engine is chosen by language (`object/language`): `"ja"` uses Sudachi
  (an external service, `SukhiFedi.Tokenizer.Sudachi`); a language with no
  engine falls back to `SukhiFedi.Tokenizer.Whitespace` (the text as is,
  which is what Datalevin would do anyway). Korean is undecided and so
  currently falls back.

  A tokenizer that is down never blocks a write: `segment/2` falls back to
  the whitespace form and says so (`{:degraded, text}`), and the caller may
  re-run it later (the original is kept, so `tokens` can always be rebuilt).
  """

  @callback segment(text :: String.t(), opts :: keyword()) :: {:ok, String.t()} | {:error, term()}

  @type result :: {:ok, String.t()} | {:degraded, String.t()}

  @spec segment(String.t(), String.t() | nil, keyword()) :: result()
  def segment(text, language, opts \\ []) when is_binary(text) do
    engines = Keyword.get(opts, :engines, engines())

    case engine(language, engines) do
      SukhiFedi.Tokenizer.Whitespace ->
        {:ok, SukhiFedi.Tokenizer.Whitespace.segment!(text)}

      mod ->
        case mod.segment(text, Keyword.get(opts, :engine_opts, [])) do
          {:ok, out} -> {:ok, out}
          {:error, _} -> {:degraded, SukhiFedi.Tokenizer.Whitespace.segment!(text)}
        end
    end
  end

  @doc "Primary language subtag: `\"ja-JP\"` → `\"ja\"`."
  @spec primary(String.t() | nil) :: String.t() | nil
  def primary(nil), do: nil
  def primary(tag), do: tag |> String.downcase() |> String.split(["-", "_"], parts: 2) |> hd()

  defp engine(language, engines),
    do: Map.get(engines, primary(language), SukhiFedi.Tokenizer.Whitespace)

  defp engines,
    do: Application.get_env(:sukhi_fedi, :tokenizers, %{"ja" => SukhiFedi.Tokenizer.Sudachi})
end
