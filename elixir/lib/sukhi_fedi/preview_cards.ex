# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.PreviewCards do
  @moduledoc """
  Link preview cards (FEP-8967). When a note carries a link, a background
  job fetches that page and pulls its OpenGraph tags into a small card —
  title, description, image — that clients render under the post.

  Fetching an arbitrary, user-supplied URL is the classic SSRF hazard, so
  the fetch is fenced:

    * only `http`/`https`, only ports 80/443 (or the scheme default),
    * the host must resolve entirely to public IP addresses — no
      loopback, private, link-local or unique-local ranges (which is
      where cloud metadata endpoints and internal services live),
    * redirects are NOT followed (a 3xx just yields no card), so a
      public URL can't bounce us onto an internal one,
    * the body is size-capped (via `HttpFetch`) and the response must be
      HTML.

  One card per note; a re-generation replaces it. Cards are never made for
  our own domain's links.
  """

  import Ecto.Query

  alias SukhiFedi.Fedi.HttpFetch
  alias SukhiFedi.Repo
  alias SukhiFedi.Schema.PreviewCard

  @url_re ~r{https?://[^\s"'<>)\]]+}i
  @user_agent "sukhi-fedi/1.0 (+link-preview)"
  @timeout 5_000

  @doc "Whether link-preview generation runs (off in tests)."
  def enabled?, do: Application.get_env(:sukhi_fedi, :link_previews, true)

  @doc """
  The first external (non-local) http(s) link in `content`, or nil. Reads
  the raw text, so it catches both a linkified `<a href>` and a bare URL.
  """
  @spec first_link(String.t() | nil, String.t()) :: String.t() | nil
  def first_link(content, our_domain) when is_binary(content) do
    @url_re
    |> Regex.scan(content)
    |> Enum.map(fn [u] -> String.trim_trailing(u, ".") end)
    |> Enum.find(&external?(&1, our_domain))
  end

  def first_link(_content, _our_domain), do: nil

  defp external?(url, our_domain) do
    case URI.parse(url) do
      %URI{scheme: s, host: h} when s in ["http", "https"] and is_binary(h) and h != "" ->
        String.downcase(h) != String.downcase(our_domain)

      _ ->
        false
    end
  end

  @doc "Cards keyed by note id, for the status hydration batch."
  @spec for_notes([integer()]) :: %{integer() => map()}
  def for_notes(note_ids) when is_list(note_ids) do
    from(c in PreviewCard, where: c.note_id in ^note_ids)
    |> Repo.all()
    |> Map.new(fn c -> {c.note_id, card_map(c)} end)
  end

  defp card_map(%PreviewCard{} = c) do
    %{
      url: c.url,
      title: c.title,
      description: c.description,
      image: c.image,
      type: c.type,
      provider_name: c.provider_name
    }
  end

  @doc "Fetch `url`, parse its card, and store it against `note_id` (replacing any prior)."
  @spec generate(integer(), String.t()) :: :ok
  def generate(note_id, url) do
    case fetch_card(url) do
      {:ok, attrs} -> upsert(note_id, attrs)
      :error -> :ok
    end

    :ok
  end

  defp upsert(note_id, attrs) do
    %PreviewCard{}
    |> PreviewCard.changeset(Map.put(attrs, "note_id", note_id))
    |> Repo.insert(
      on_conflict: {:replace_all_except, [:id, :note_id, :created_at]},
      conflict_target: :note_id
    )
  end

  # ── safe fetch ───────────────────────────────────────────────────────────

  @spec fetch_card(String.t()) :: {:ok, map()} | :error
  def fetch_card(url) when is_binary(url) do
    with {:ok, %URI{host: host}} <- valid_uri(url),
         :ok <- ensure_public_host(host),
         {:ok, %Req.Response{status: status} = resp} when status in 200..299 <-
           HttpFetch.capped_get(url, fetch_opts()),
         :ok <- ensure_html(resp) do
      {:ok, parse_og(resp.body, url)}
    else
      _ -> :error
    end
  end

  defp fetch_opts do
    [
      redirect: false,
      headers: [{"user-agent", @user_agent}, {"accept", "text/html,application/xhtml+xml"}],
      connect_options: [timeout: @timeout],
      receive_timeout: @timeout,
      retry: false
    ]
  end

  # http/https only, host present, only default-ish ports (no SSRF via :22 etc.).
  defp valid_uri(url) do
    case URI.parse(url) do
      %URI{scheme: s, host: h, port: p} = uri
      when s in ["http", "https"] and is_binary(h) and h != "" and p in [nil, 80, 443] ->
        {:ok, uri}

      _ ->
        :error
    end
  end

  defp ensure_html(resp) do
    ct = resp |> Req.Response.get_header("content-type") |> List.first() || ""
    if String.contains?(ct, "html"), do: :ok, else: :error
  end

  # The host must resolve only to public addresses. We check both A and
  # AAAA records and require at least one, all public.
  defp ensure_public_host(host) do
    v4 = resolve(host, :inet)
    v6 = resolve(host, :inet6)
    addrs = v4 ++ v6

    cond do
      addrs == [] -> :error
      Enum.all?(addrs, &public_ip?/1) -> :ok
      true -> :error
    end
  end

  defp resolve(host, family) do
    case :inet.getaddrs(to_charlist(host), family) do
      {:ok, addrs} -> addrs
      _ -> []
    end
  end

  # IPv4 private/special ranges.
  defp public_ip?({10, _, _, _}), do: false
  defp public_ip?({127, _, _, _}), do: false
  defp public_ip?({169, 254, _, _}), do: false
  defp public_ip?({172, b, _, _}) when b in 16..31, do: false
  defp public_ip?({192, 168, _, _}), do: false
  defp public_ip?({100, b, _, _}) when b in 64..127, do: false
  defp public_ip?({0, _, _, _}), do: false
  defp public_ip?({a, _, _, _}) when a >= 224, do: false
  defp public_ip?({_, _, _, _}), do: true
  # IPv6 loopback / unspecified.
  defp public_ip?({0, 0, 0, 0, 0, 0, 0, 1}), do: false
  defp public_ip?({0, 0, 0, 0, 0, 0, 0, 0}), do: false
  # IPv4-mapped (::ffff:a.b.c.d) → judge by the embedded v4.
  defp public_ip?({0, 0, 0, 0, 0, 0xFFFF, ab, cd}),
    do: public_ip?({div(ab, 256), rem(ab, 256), div(cd, 256), rem(cd, 256)})

  # fc00::/7 unique-local, fe80::/10 link-local.
  defp public_ip?({h, _, _, _, _, _, _, _}) when h >= 0xFC00 and h <= 0xFDFF, do: false
  defp public_ip?({h, _, _, _, _, _, _, _}) when h >= 0xFE80 and h <= 0xFEBF, do: false
  defp public_ip?({_, _, _, _, _, _, _, _}), do: true

  # ── OpenGraph parse (regex, no HTML-parser dep) ──────────────────────────

  @doc "Extract a card map from a page's HTML and its URL. Public for testing."
  @spec parse_og(binary(), String.t()) :: map()
  def parse_og(html, url) when is_binary(html) do
    %{
      "url" => og(html, "og:url") || url,
      "title" => trunc_at(og(html, "og:title") || title_tag(html) || "", 500),
      "description" => trunc_at(og(html, "og:description") || meta_name(html, "description") || "", 1000),
      "image" => og(html, "og:image"),
      "type" => og(html, "og:type") || "link",
      "provider_name" => og(html, "og:site_name") || URI.parse(url).host || ""
    }
  end

  def parse_og(_html, url), do: %{"url" => url, "title" => "", "type" => "link"}

  # `<meta property="og:x" content="...">` — try both attribute orders.
  defp og(html, prop) do
    meta_attr(html, "property", prop) || meta_attr(html, "name", prop)
  end

  defp meta_name(html, name), do: meta_attr(html, "name", name)

  defp meta_attr(html, key, val) do
    forward =
      Regex.run(
        ~r/<meta[^>]+#{key}=["']#{Regex.escape(val)}["'][^>]+content=["']([^"']*)["']/i,
        html
      )

    backward =
      Regex.run(
        ~r/<meta[^>]+content=["']([^"']*)["'][^>]+#{key}=["']#{Regex.escape(val)}["']/i,
        html
      )

    case forward || backward do
      [_, content] -> content |> unescape() |> String.trim() |> presence()
      _ -> nil
    end
  end

  defp title_tag(html) do
    case Regex.run(~r/<title[^>]*>([^<]*)<\/title>/i, html) do
      [_, t] -> t |> unescape() |> String.trim() |> presence()
      _ -> nil
    end
  end

  defp presence(""), do: nil
  defp presence(s), do: s

  defp trunc_at(s, n) when byte_size(s) <= n, do: s
  defp trunc_at(s, n), do: String.slice(s, 0, n)

  defp unescape(s) do
    s
    |> String.replace("&amp;", "&")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&quot;", "\"")
    |> String.replace("&#39;", "'")
    |> String.replace("&#x27;", "'")
  end
end
