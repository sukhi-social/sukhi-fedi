# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Backend do
  @moduledoc """
  The one place that says which implementation answers a *seam*.

  A seam is a piece of pure computation — bytes or text in, a value out, no
  database, no network, no process state — that is a candidate for moving
  into native code (a NIF) one day, and that is already written in Elixir.
  Each has a behaviour (what any implementation must do), an `Elixir`
  implementation (what runs today), and a facade the rest of the code calls
  (`HTML.sanitize/1`, `Linkify.run/2`, `PreviewCards.parse_og/2`,
  `Markdown.to_html/2`). The facade
  calls `call/3`; nothing else needs to know which implementation answered.

      seam               behaviour                           default
      :html_sanitizer    SukhiFedi.HTML.Sanitizer            …Sanitizer.Elixir
      :linkify_scanner   SukhiFedi.Linkify.Scanner           …Scanner.Elixir
      :preview_meta      SukhiFedi.PreviewCards.Meta         …Meta.Elixir
      :markdown          SukhiFedi.Markdown.Renderer         …Renderer.Elixir

  ## Switching, and trying one out first

      # which implementation answers
      config :sukhi_fedi, :backends, html_sanitizer: SukhiFedi.HTML.Sanitizer.NIF

      # ask another one too, and log when it disagrees; the answer is still
      # the primary's, and whatever the shadow raises is swallowed
      config :sukhi_fedi, :shadow_backends, html_sanitizer: SukhiFedi.HTML.Sanitizer.NIF

  This is `Fedi.OjakShadow` for any seam. A NIF goes in by: implementing the
  behaviour, adding it to `implementations/1` (so the contract tests run
  against it), shadowing it on real traffic until the log is quiet, and only
  then making it the primary. See docs/native-seams.md.

  What a log line carries: the seam, the function, the two answers' sizes and
  a hash of the arguments. Never the arguments — they are users' posts.
  """

  require Logger

  @seams %{
    html_sanitizer: SukhiFedi.HTML.Sanitizer.Elixir,
    linkify_scanner: SukhiFedi.Linkify.Scanner.Elixir,
    preview_meta: SukhiFedi.PreviewCards.Meta.Elixir,
    markdown: SukhiFedi.Markdown.Renderer.Elixir
  }

  @type seam :: :html_sanitizer | :linkify_scanner | :preview_meta | :markdown

  @doc "The implementation answering `seam`."
  @spec impl(seam()) :: module()
  def impl(seam) do
    :sukhi_fedi |> Application.get_env(:backends, []) |> Keyword.get(seam, default(seam))
  end

  @doc "Every implementation of `seam` the contract tests should hold to the same answers."
  @spec implementations(seam()) :: [module()]
  def implementations(seam), do: [default(seam)]

  @doc "Call `fun` on the implementation of `seam`, shadowing it if one is configured."
  @spec call(seam(), atom(), [term()]) :: term()
  def call(seam, fun, args) do
    answer = apply(impl(seam), fun, args)
    shadow(seam, fun, args, answer)
    answer
  end

  defp default(seam), do: Map.fetch!(@seams, seam)

  defp shadow(seam, fun, args, answer) do
    case :sukhi_fedi |> Application.get_env(:shadow_backends, []) |> Keyword.get(seam) do
      nil -> :ok
      module -> compare(seam, fun, args, answer, module)
    end
  end

  defp compare(seam, fun, args, answer, module) do
    other = apply(module, fun, args)

    if other != answer do
      Logger.warning(
        "backend shadow disagreement on #{seam}.#{fun}: " <>
          "primary #{size(answer)} / #{inspect(module)} #{size(other)}, args hash #{:erlang.phash2(args)}"
      )
    end

    :ok
  rescue
    _ -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp size(term) when is_binary(term), do: "#{byte_size(term)}B"
  defp size(term), do: "#{:erlang.external_size(term)}B"
end
