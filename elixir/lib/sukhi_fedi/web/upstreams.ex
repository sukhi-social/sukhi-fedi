# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Web.Upstreams do
  @moduledoc """
  The web fronts (web-simple, web-next, web-board, web-lobby…) that sit
  behind this gateway, and which of them answers a path.

  This module is the one place that decides it. It holds no state of its
  own: `SukhiFedi.Web.Upstreams.Registry` keeps the table fresh, this
  module compiles it and reads it.

  ## Two inputs, kept apart

    * **`SUKHI_INSTANCE_CONFIG`** (operator): the required non-secret JSON file
      names the upstreams and where they are. Nothing a web says about itself
      can add a name here.
    * **`/.sukhi/web.json`** (each web, a static file): what that web *can*
      answer. We fetch it from the upstream's own URL; browsers never can,
      because a path with a dot-led segment is never forwarded (`dot_path?/1`).

          {"name": "web-next", "version": "…",
           "claims": [{"methods": ["GET","HEAD"], "path": "/timeline"},
                      {"methods": ["POST"],       "path": "/compose"},
                      {"path": "/@:acct/*"}],
           "cookies": ["sukhi_sid"]}

      `methods` defaults to `["GET","HEAD"]`. `cookies` names the only
      cookies that cross in either direction; none by default.

    * **`routes`** in `SUKHI_INSTANCE_CONFIG`: ordered `pattern`/`frontend`
      objects, **first match wins** (the way an nginx `location` list reads),
      so write the specific rows first:

          [{"pattern":"/home","upstream":"web-lobby"},
           {"pattern":"/**","upstream":"web-next"}]

      A row only counts when the upstream it names also claims the path.
      A path no row decides goes to the one upstream that claims it; if
      several do, nobody is chosen (the operator has not said), rather
      than picking silently.

  ## Path patterns

  `/a/b` literal; `:x` one segment (`@:acct` = a segment starting with `@`);
  `*` or `**` the rest of the path, including nothing.

  ## Never forwarded

  A path with any segment starting with `.` — `/.well-known/…`, `/.env`,
  `/.sukhi/web.json` — is the gateway's alone. It is checked before any
  table is read, so a web cannot claim it and a missing table cannot expose it.
  """

  @type segment :: {:lit, String.t()} | {:param, String.t()} | :rest
  @type pattern :: [segment()]
  @type claim :: %{methods: [String.t()], pattern: pattern()}
  @type upstream :: %{
          name: String.t(),
          url: String.t(),
          claims: [claim()],
          cookies: [String.t()]
        }
  @type table :: %{upstreams: %{String.t() => upstream()}, routes: [{pattern(), String.t()}]}

  @default_methods ["GET", "HEAD"]
  @key {__MODULE__, :table}

  # ── The path is the gateway's alone ──────────────────────────────

  @spec dot_path?([String.t()]) :: boolean()
  def dot_path?(segments), do: Enum.any?(segments, &String.starts_with?(&1, "."))

  # ── Reading ─────────────────────────────────────────────────────

  @doc "Who answers `method` + `segments`: `{:ok, upstream}` or `:none`."
  @spec lookup(String.t(), [String.t()]) :: {:ok, upstream()} | :none
  def lookup(method, segments) do
    case :persistent_term.get(@key, nil) do
      nil -> :none
      table -> resolve(table, method, segments)
    end
  end

  @doc false
  @spec resolve(table(), String.t(), [String.t()]) :: {:ok, upstream()} | :none
  def resolve(%{upstreams: ups, routes: routes}, method, segments) do
    if dot_path?(segments) do
      :none
    else
      claims? = fn name -> claims?(ups[name], method, segments) end

      case Enum.find(routes, fn {pat, name} -> matches?(pat, segments) and claims?.(name) end) do
        {_pat, name} ->
          {:ok, ups[name]}

        nil ->
          case for({name, _} <- ups, claims?.(name), do: name) do
            [name] -> {:ok, ups[name]}
            _ -> :none
          end
      end
    end
  end

  defp claims?(nil, _method, _segments), do: false

  defp claims?(%{claims: claims}, method, segments) do
    Enum.any?(claims, fn %{methods: ms, pattern: pat} ->
      method in ms and matches?(pat, segments)
    end)
  end

  @doc false
  @spec matches?(pattern(), [String.t()]) :: boolean()
  def matches?([], []), do: true
  def matches?([:rest], _), do: true
  def matches?([{:lit, s} | p], [s | r]), do: matches?(p, r)

  def matches?([{:param, pre} | p], [seg | r]),
    do: byte_size(seg) > byte_size(pre) and String.starts_with?(seg, pre) and matches?(p, r)

  def matches?(_, _), do: false

  # ── Writing (the Registry calls these) ───────────────────────────

  @doc false
  def put(table), do: :persistent_term.put(@key, table)

  @doc false
  def clear, do: :persistent_term.erase(@key)

  # ── Parsing ─────────────────────────────────────────────────────

  @doc "`name=url,name=url` → `%{name => url}`; malformed items are dropped."
  @spec parse_upstreams(String.t() | nil) :: %{String.t() => String.t()}
  def parse_upstreams(nil), do: %{}

  def parse_upstreams(str) do
    for item <- String.split(str, ",", trim: true),
        [name, url] <- [String.split(String.trim(item), "=", parts: 2)],
        name = String.trim(name),
        url = url |> String.trim() |> String.trim_trailing("/"),
        name != "" and String.starts_with?(url, ["http://", "https://"]),
        into: %{},
        do: {name, url}
  end

  @doc "`pattern=name,pattern=name` → ordered `[{pattern, name}]`."
  @spec parse_routes(String.t() | nil) :: [{pattern(), String.t()}]
  def parse_routes(nil), do: []

  def parse_routes(str) do
    for item <- String.split(str, ",", trim: true),
        [pat, name] <- [String.split(String.trim(item), "=", parts: 2)],
        String.starts_with?(pat, "/") and String.trim(name) != "",
        do: {compile_pattern(pat), String.trim(name)}
  end

  @spec compile_pattern(String.t()) :: pattern()
  def compile_pattern(path) do
    path
    |> String.split("/", trim: true)
    |> Enum.map(fn
      s when s in ["*", "**"] -> :rest
      s -> segment(s)
    end)
  end

  defp segment(s) do
    case Regex.run(~r/^([^:]*):[A-Za-z_]\w*$/, s) do
      [_, pre] -> {:param, pre}
      nil -> {:lit, s}
    end
  end

  @doc """
  A web's own `web.json` → `{:ok, %{claims, cookies}}`. A claim that is not
  a string path is dropped, and a claim under a dot-led segment is dropped
  with it (it could never be served; saying so is the web's mistake).
  """
  @spec parse_manifest(binary()) :: {:ok, %{claims: [claim()], cookies: [String.t()]}} | :error
  def parse_manifest(json) do
    with {:ok, %{"claims" => claims} = m} when is_list(claims) <- Jason.decode(json) do
      parsed =
        for %{"path" => path} = c <- claims,
            is_binary(path),
            String.starts_with?(path, "/"),
            pattern = compile_pattern(path),
            not dot_pattern?(pattern) do
          %{methods: methods(c["methods"]), pattern: pattern}
        end

      cookies = for c <- List.wrap(m["cookies"]), is_binary(c), do: c
      {:ok, %{claims: parsed, cookies: cookies}}
    else
      _ -> :error
    end
  end

  defp dot_pattern?(pattern),
    do:
      Enum.any?(pattern, fn
        {:lit, s} -> String.starts_with?(s, ".")
        {:param, pre} -> String.starts_with?(pre, ".")
        _ -> false
      end)

  defp methods(ms) when is_list(ms) and ms != [] do
    case for(m <- ms, is_binary(m), do: String.upcase(m)) do
      [] -> @default_methods
      list -> list
    end
  end

  defp methods(_), do: @default_methods

  @doc """
  Rows the config will never reach: anything after a row that matches
  every path. Returned for the Registry to log at load.
  """
  @spec shadowed_routes([{pattern(), String.t()}]) :: [{pattern(), String.t()}]
  def shadowed_routes(routes) do
    case Enum.find_index(routes, fn {pat, _} -> pat == [:rest] end) do
      nil -> []
      i -> Enum.drop(routes, i + 1)
    end
  end
end
