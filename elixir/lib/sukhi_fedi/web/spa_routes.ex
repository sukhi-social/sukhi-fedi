# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Web.SpaRoutes do
  @moduledoc """
  Which paths are pages of the SPA, as the SPA itself says.

  A browser GET for a page is answered with the SPA shell, and the shell
  renders whatever the URL names. The server used to carry a hand-kept
  `get "/lists/:id"` for each page; a page added to the web build without
  its twin in `router.ex` worked on in-app clicks and 404ed on a direct link
  or a reload, and that happened again and again.

  Now the build writes `routes.json` (web/scripts/routes-manifest.mjs) from
  SvelteKit's own route table and it travels with the assets, like
  `.static-build.json` does. This module reads it through `StaticFiles`, so
  the same "which tree answers" rules apply and the list always belongs to
  the build whose `index.html` is served.

      {"routes": ["/", "/lists/[id]", "/@[acct]/followers", ...]}

  The ids are SvelteKit's: `[x]` is one segment (also inside one, as in
  `@[acct]`), `[...x]` the rest of the path, `[[x]]` an optional segment,
  `(group)` no segment.

  No manifest — no build yet, or a tree from before it existed — is
  reported as such (`:no_manifest`), not as "not a page": the caller knows
  whether something else can answer. With the SSR renderer it can (the Node
  next door knows its own routes and 404s for the rest), which is also what
  keeps a pushed tree from before `routes.json` working through a deploy.
  """

  alias SukhiFedi.Web.StaticFiles

  @manifest "routes.json"
  @cache_key {__MODULE__, :compiled}

  @type segment ::
          {:lit, String.t()}
          | {:param, prefix :: String.t(), suffix :: String.t()}
          | :rest
          | :optional

  @doc """
  Is `segments` (the request path split on `/`) a page of the SPA?

  `:page` and `:not_page` are the build's answer; `:no_manifest` means there
  is no build to ask.
  """
  @spec classify([String.t()]) :: :page | :not_page | :no_manifest
  def classify(segments) when is_list(segments) do
    case routes() do
      nil -> :no_manifest
      routes -> if Enum.any?(routes, &match_route?(&1, segments)), do: :page, else: :not_page
    end
  end

  @doc false
  @spec compile(binary()) :: [[segment()]]
  def compile(json) do
    with {:ok, %{"routes" => ids}} when is_list(ids) <- Jason.decode(json) do
      for id <- ids, is_binary(id), do: compile_route(id)
    else
      _ -> []
    end
  end

  @doc false
  @spec match_route?([segment()], [String.t()]) :: boolean()
  def match_route?([], []), do: true
  def match_route?([:rest], _), do: true
  def match_route?([:optional | rest], []), do: match_route?(rest, [])

  def match_route?([:optional | rest], [_ | segs] = all),
    do: match_route?(rest, segs) or match_route?(rest, all)

  def match_route?([seg | rest], [s | segs]) do
    segment_matches?(seg, s) and match_route?(rest, segs)
  end

  def match_route?(_, _), do: false

  defp segment_matches?({:lit, lit}, s), do: lit == s

  defp segment_matches?({:param, prefix, suffix}, s) do
    String.starts_with?(s, prefix) and String.ends_with?(s, suffix) and
      byte_size(s) > byte_size(prefix) + byte_size(suffix)
  end

  defp compile_route(id) do
    id
    |> String.split("/", trim: true)
    |> Enum.reject(&group?/1)
    |> Enum.map(&compile_segment/1)
  end

  defp group?(seg), do: String.starts_with?(seg, "(") and String.ends_with?(seg, ")")

  defp compile_segment("[[" <> _), do: :optional
  defp compile_segment("[..." <> _), do: :rest

  defp compile_segment(seg) do
    case Regex.run(~r/^(.*?)\[[^\]]+\](.*)$/, seg) do
      [_, prefix, suffix] -> {:param, prefix, suffix}
      _ -> {:lit, seg}
    end
  end

  # Read on every call, compiled once per distinct file content: a pushed
  # tree replaces routes.json without a restart, and the content (unlike
  # an mtime, see StaticFiles) cannot be stale.
  defp routes do
    with {_source, path} <- StaticFiles.resolve(@manifest),
         {:ok, json} <- File.read(path) do
      case :persistent_term.get(@cache_key, nil) do
        {^json, compiled} ->
          compiled

        _ ->
          compiled = compile(json)
          :persistent_term.put(@cache_key, {json, compiled})
          compiled
      end
    else
      _ -> nil
    end
  end
end
