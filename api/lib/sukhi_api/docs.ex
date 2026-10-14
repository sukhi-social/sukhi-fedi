# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiApi.Docs do
  @moduledoc """
  The API reference, derived from the route list and nothing else.

  A route is `{method, path, handler}` or `{method, path, handler, opts}`
  (see `SukhiApi.Capability`). That already says what exists, who may call
  it (`scope:` or public) and which capability it belongs to (the handler's
  module). So there is nothing to annotate: add a route and it is on the
  page; remove the file and it is gone.

  The one-line summary of an endpoint is the first line of the handler's
  `@doc` when the docs are present, and otherwise its function name spelled
  out (`list_accounts` → "List accounts"; a bare `show` borrows the last
  word of the path: "Show custom emojis"). A release strips doc chunks from
  its beams, so in production it is almost always the function name — which
  is why the names, not the docs, are what to keep readable.

  This describes the *surface*, not the shapes: no request or response
  schema is derived, because handlers here are plain functions over a map
  and nothing declares one. Pure: `entries/1`, `html/1` and `openapi/2` take
  the routes as an argument; `SukhiApi.Capabilities.ApiDocs` hands them
  `SukhiApi.Registry.routes/0`.
  """

  @type entry :: %{
          method: String.t(),
          path: String.t(),
          scope: String.t() | nil,
          group: String.t(),
          operation: String.t(),
          summary: String.t(),
          params: [String.t()]
        }

  @method_order %{"GET" => 0, "POST" => 1, "PUT" => 2, "PATCH" => 3, "DELETE" => 4}
  @generic ~w(index show create update delete destroy get put post)

  # ── routes → entries ─────────────────────────────────────────────────────

  @doc "One entry per route, grouped and ordered the way the page shows them."
  @spec entries([SukhiApi.Capability.route()]) :: [entry()]
  def entries(routes) do
    routes
    |> Enum.map(&entry/1)
    |> Enum.sort_by(&{&1.group, &1.path, Map.get(@method_order, &1.method, 9)})
  end

  defp entry({method, path, handler}), do: entry({method, path, handler, []})

  defp entry({method, path, handler, opts}) do
    info = Function.info(handler)
    module = Keyword.fetch!(info, :module)
    # `&index/1` has the function's own name; an anonymous `fn` has a compiler
    # artefact ("-routes/0-fun-0-"), so it is summarised from the path instead.
    name = named(Keyword.fetch!(info, :name))

    %{
      method: method |> to_string() |> String.upcase(),
      path: path,
      scope: Keyword.get(opts, :scope),
      group: group_name(module),
      operation: "#{inspect(module)}.#{name || operation_id(method, path)}",
      summary: summary(module, name, path),
      params: for(":" <> p <- String.split(path, "/"), do: p)
    }
  end

  @doc "`SukhiApi.Capabilities.MastodonStatuses` → \"Mastodon statuses\"; `OAuthApps` → \"OAuth apps\"."
  @spec group_name(module()) :: String.t()
  def group_name(module) do
    module
    |> Module.split()
    |> List.last()
    |> String.replace(~r/([a-z0-9])([A-Z])/, "\\1 \\2")
    |> String.split(" ")
    |> Enum.map(&word/1)
    |> Enum.join(" ")
    |> upcase_first()
  end

  # `Api` is an acronym here; `OAuth` keeps its capitals (two or more); the
  # rest are lower case, so the name reads as a phrase.
  defp word("Api"), do: "API"
  defp word(w), do: if(String.length(String.replace(w, ~r/[^A-Z]/, "")) >= 2, do: w, else: String.downcase(w))

  defp upcase_first(<<first::utf8, rest::binary>>), do: String.upcase(<<first::utf8>>) <> rest

  defp named(name) do
    if String.starts_with?(Atom.to_string(name), "-"), do: nil, else: name
  end

  defp operation_id(method, path), do: "#{method}_#{last_static_segment(path)}"

  defp summary(_module, nil, path), do: spelled_out(:anonymous, path)
  defp summary(module, name, path), do: doc_line(module, name) || spelled_out(name, path)

  # The first line of the handler's @doc, if its docs were compiled in.
  defp doc_line(module, name) do
    with {:docs_v1, _, _, _, _, _, docs} <- Code.fetch_docs(module),
         {_, _, _, %{"en" => text}, _} <-
           Enum.find(docs, &match?({{:function, ^name, 1}, _, _, %{"en" => _}, _}, &1)) do
      text |> String.split("\n", parts: 2) |> hd() |> String.trim() |> blank_to_nil()
    else
      _ -> nil
    end
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(s), do: s

  defp spelled_out(:anonymous, path), do: path |> last_static_segment() |> String.replace("_", " ") |> String.capitalize()

  defp spelled_out(name, path) do
    words = name |> to_string() |> String.trim_trailing("!") |> String.split("_")

    words =
      if to_string(name) in @generic do
        words ++ String.split(last_static_segment(path), "_")
      else
        words
      end

    words |> Enum.join(" ") |> String.capitalize()
  end

  defp last_static_segment(path) do
    path
    |> String.split("/", trim: true)
    |> Enum.reject(&String.starts_with?(&1, ":"))
    |> List.last()
    |> Kernel.||("")
    |> String.replace(~r/\.json$/, "")
  end

  # ── HTML ─────────────────────────────────────────────────────────────────

  @doc "The reference as one self-contained page: no external script, style or font."
  @spec html([SukhiApi.Capability.route()]) :: String.t()
  def html(routes) do
    entries = entries(routes)
    groups = Enum.group_by(entries, & &1.group)
    names = groups |> Map.keys() |> Enum.sort()

    """
    <!doctype html>
    <html lang="en">
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>sukhi-fedi API</title>
    <style>#{css()}</style>
    <header>
      <h1>sukhi-fedi API</h1>
      <p>#{length(entries)} endpoints in #{length(names)} groups · <a href="/api/docs.json">OpenAPI</a> ·
        <span class="lede">a <b>scope</b> needs an OAuth bearer holding it; <b>public</b> needs nothing.
        Shapes of requests and responses are not described here.</span></p>
      <input id="q" type="search" placeholder="filter: path, method, scope…" aria-label="filter" autocomplete="off">
    </header>
    <nav>#{Enum.map_join(names, " ", fn n -> ~s(<a href="##{slug(n)}">#{esc(n)}</a>) end)}</nav>
    <main>
    #{Enum.map_join(names, "\n", fn n -> section(n, groups[n]) end)}
    </main>
    <script>#{js()}</script>
    """
  end

  defp section(name, entries) do
    """
    <section id="#{slug(name)}">
    <h2>#{esc(name)} <small>#{length(entries)}</small></h2>
    #{Enum.map_join(entries, "\n", &row/1)}
    </section>
    """
  end

  defp row(e) do
    scope =
      case e.scope do
        nil -> ~s(<span class="scope pub">public</span>)
        s -> ~s(<span class="scope">#{esc(s)}</span>)
      end

    ~s(<div class="row" data-q="#{esc(String.downcase("#{e.method} #{e.path} #{e.scope} #{e.summary}"))}">) <>
      ~s(<b class="m #{String.downcase(e.method)}">#{e.method}</b>) <>
      ~s(<code>#{path_html(e.path)}</code>#{scope}<span class="sum">#{esc(e.summary)}</span></div>)
  end

  # `:id` segments stand out
  defp path_html(path) do
    path
    |> String.split("/")
    |> Enum.map_join("/", fn
      ":" <> p -> ~s(<i>:#{esc(p)}</i>)
      seg -> esc(seg)
    end)
  end

  @doc false
  def esc(text) do
    text
    |> to_string()
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
  end

  defp slug(name), do: name |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "-")

  defp css do
    """
    :root{--bg:#fff;--fg:#1c1c20;--dim:#6b6b76;--line:#e6e6ea;--chip:#f1f1f4;--get:#0b7a4b;--post:#1d5fd6;--put:#a35a00;--patch:#7b3fb8;--delete:#c0392b;--pub:#0b7a4b}
    @media (prefers-color-scheme:dark){:root{--bg:#131316;--fg:#e8e8ec;--dim:#9a9aa6;--line:#2a2a30;--chip:#1f1f25;--get:#46c28a;--post:#6f9cff;--put:#e0a24a;--patch:#b88af0;--delete:#ef7f72;--pub:#46c28a}}
    *{box-sizing:border-box}
    body{margin:0 auto;max-width:62rem;padding:1rem 16px 4rem;background:var(--bg);color:var(--fg);font:15px/1.45 system-ui,sans-serif}
    h1{margin:.2rem 0;font-size:1.3rem}h2{margin:1.6rem 0 .3rem;font-size:1rem}h2 small{color:var(--dim);font-weight:400}
    p{margin:.2rem 0;color:var(--dim)}a{color:inherit}.lede{display:block}
    input{width:100%;margin:.7rem 0;padding:.5rem .7rem;border:1px solid var(--line);border-radius:6px;background:var(--bg);color:var(--fg);font:inherit}
    nav{display:flex;flex-wrap:wrap;gap:.3rem .8rem;font-size:.85rem;color:var(--dim)}
    .row{display:grid;grid-template-columns:4.2rem 1fr;gap:0 .6rem;align-items:baseline;padding:.3rem 0;border-bottom:1px solid var(--line)}
    .row[hidden],section[hidden]{display:none}
    code{font:13px/1.4 ui-monospace,monospace;word-break:break-all}code i{color:var(--dim)}
    .m{font:700 11px ui-monospace,monospace}.get{color:var(--get)}.post{color:var(--post)}.put{color:var(--put)}.patch{color:var(--patch)}.delete{color:var(--delete)}
    .scope{grid-column:2;justify-self:start;margin-top:.1rem;padding:0 .4rem;border-radius:4px;background:var(--chip);font:11px ui-monospace,monospace;color:var(--dim)}
    .scope.pub{color:var(--pub)}.sum{grid-column:2;color:var(--dim);font-size:.85rem}
    @media (min-width:700px){.row{grid-template-columns:4.2rem minmax(0,1fr) 11rem 15rem}.scope,.sum{grid-column:auto}.sum{text-align:right}}
    """
    |> String.replace("\n", "")
  end

  defp js do
    """
    var q=document.getElementById('q');q.addEventListener('input',function(){var s=q.value.trim().toLowerCase();
    document.querySelectorAll('.row').forEach(function(r){r.hidden=s&&r.dataset.q.indexOf(s)<0});
    document.querySelectorAll('section').forEach(function(x){x.hidden=!x.querySelector('.row:not([hidden])')})});
    """
    |> String.replace("\n", "")
  end

  # ── OpenAPI ──────────────────────────────────────────────────────────────

  @doc """
  A minimal OpenAPI 3.1 document: paths, methods, tags, one-line summaries,
  path parameters and the OAuth scope each operation needs. No schemas
  (none are declared anywhere to derive them from).
  """
  @spec openapi([SukhiApi.Capability.route()], String.t()) :: map()
  def openapi(routes, version) do
    entries = entries(routes)

    scopes =
      entries
      |> Enum.map(& &1.scope)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.sort()
      |> Map.new(&{&1, &1})

    paths =
      entries
      |> Enum.group_by(&openapi_path(&1.path))
      |> Map.new(fn {path, es} -> {path, Map.new(es, &{String.downcase(&1.method), operation(&1)})} end)

    %{
      "openapi" => "3.1.0",
      "info" => %{"title" => "sukhi-fedi API", "version" => version},
      "paths" => paths,
      "components" => %{
        "securitySchemes" => %{
          "oauth2" => %{
            "type" => "oauth2",
            "flows" => %{
              "authorizationCode" => %{
                "authorizationUrl" => "/oauth/authorize",
                "tokenUrl" => "/oauth/token",
                "scopes" => scopes
              }
            }
          }
        }
      }
    }
  end

  defp operation(e) do
    %{
      "operationId" => e.operation,
      "summary" => e.summary,
      "tags" => [e.group],
      "responses" => %{"200" => %{"description" => "OK"}}
    }
    |> put_if(e.params != [], "parameters", Enum.map(e.params, &path_param/1))
    |> put_if(e.scope != nil, "security", [%{"oauth2" => [e.scope]}])
  end

  defp path_param(name),
    do: %{"name" => name, "in" => "path", "required" => true, "schema" => %{"type" => "string"}}

  defp put_if(map, true, key, value), do: Map.put(map, key, value)
  defp put_if(map, false, _key, _value), do: map

  # `/api/v1/accounts/:id/follow` → `/api/v1/accounts/{id}/follow`
  defp openapi_path(path) do
    path
    |> String.split("/")
    |> Enum.map_join("/", fn
      ":" <> p -> "{#{p}}"
      seg -> seg
    end)
  end
end
