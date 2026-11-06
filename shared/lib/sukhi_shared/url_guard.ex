# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiShared.UrlGuard do
  @moduledoc """
  SSRF guard for outbound requests whose destination comes from attacker
  controlled data: the `host` of a WebFinger handle, an actor's inbox or
  sharedInbox, an inbox derived from a remote note's `id`, a media URL.

  Without it a hostile actor can point us at `http://169.254.169.254/…`
  (cloud metadata), `http://127.0.0.1:PORT/…` or an internal `10.x` service
  and make this node issue the request for them.

  Only `https` URLs whose host resolves to public addresses pass. A host is
  rejected if *any* address it resolves to is loopback, private, link-local,
  carrier-grade NAT, unspecified or multicast. DNS is resolved here and every
  returned address is checked, so a name that resolves to an internal IP (DNS
  rebinding) is rejected too.

  This is the one copy: the gateway and the delivery node both call it (it
  lives in `shared/`, a path dependency of each). Change a rule here and add
  a row to `shared/test/url_guard_test.exs`.
  """

  import Bitwise

  @spec safe?(term()) :: boolean()
  def safe?(url) when is_binary(url) do
    cond do
      # Test env only: Bypass stands up an http://localhost server, which a
      # real guard must reject. Never set in dev/prod.
      Application.get_env(:sukhi_shared, :disable_url_guard, false) ->
        true

      true ->
        case URI.parse(url) do
          %URI{scheme: "https", host: host} when is_binary(host) and host != "" ->
            public_host?(host)

          _ ->
            false
        end
    end
  end

  def safe?(_), do: false

  @doc """
  True when `host` resolves, and only, to public addresses. `safe?/1` is
  this plus the `https` rule; callers with their own scheme/port policy
  (link previews allow plain http) call this directly so the address
  rules stay in this one file.
  """
  @spec public_host?(String.t()) :: boolean()
  def public_host?(host) when is_binary(host), do: match?({:ok, _}, only_public(host))

  @doc """
  The addresses `host` resolves to, **only if every one is public**.
  `public_host?/1` answers the same question as a boolean; this hands back the
  answer itself so the caller can connect to exactly these addresses and
  nowhere else.

  That is the DNS-rebinding defence. Checking a name and then letting the HTTP
  client resolve it again opens a window in which a hostile resolver answers
  with a public address for the check and `127.0.0.1` for the connection.
  Closing it takes one resolution: check these addresses, then connect to
  them (`SukhiFedi.Fedi.HttpFetch` does).

  With `:disable_url_guard` set (test env only) any resolvable address passes,
  so a fetch can reach a Bypass server on localhost. `public_host?/1` ignores
  that switch, as it always has.
  """
  @spec public_addrs(String.t()) :: {:ok, [:inet.ip_address()]} | :error
  def public_addrs(host) when is_binary(host) do
    if Application.get_env(:sukhi_shared, :disable_url_guard, false) do
      case resolve(host) do
        {:ok, [_ | _]} = ok -> ok
        _ -> :error
      end
    else
      only_public(host)
    end
  end

  defp only_public(host) do
    case resolve(host) do
      {:ok, [_ | _] = addrs} -> if Enum.all?(addrs, &public_ip?/1), do: {:ok, addrs}, else: :error
      _ -> :error
    end
  end

  # One lookup per address family — the only name resolution in the whole
  # fetch path (`HttpFetch` connects to what this returns). The resolver is
  # `:inet.getaddrs/2` unless a test swaps it (`:resolver`, a 2-arity fun):
  # that is how the DNS-rebinding test proves a second, different answer
  # is never asked for.
  defp resolve(host) do
    cl = String.to_charlist(host)
    lookup = Application.get_env(:sukhi_shared, :resolver, &:inet.getaddrs/2)

    case {lookup.(cl, :inet), lookup.(cl, :inet6)} do
      {{:ok, a}, {:ok, b}} -> {:ok, a ++ b}
      {{:ok, a}, _} -> {:ok, a}
      {_, {:ok, b}} -> {:ok, b}
      _ -> :error
    end
  end

  # ── IPv4 ───────────────────────────────────────────────────────────────
  defp public_ip?({a, b, c, _d}) do
    cond do
      a == 0 -> false
      a == 10 -> false
      a == 127 -> false
      a == 169 and b == 254 -> false
      a == 172 and b in 16..31 -> false
      a == 192 and b == 168 -> false
      # 192.0.0.0/24 (IETF protocol assignments) and 192.0.2.0/24 (TEST-NET-1)
      # only. `b == 0` refused 192.0.0.0/16 whole, which swallowed
      # 192.0.64.0/18 — Automattic's (Gravatar, WordPress.com) ordinary public
      # space; a remote avatar there came back 502 from /proxy/avatar
      # (2026-09-22).
      a == 192 and b == 0 and c in [0, 2] -> false
      a == 100 and b in 64..127 -> false
      a >= 224 -> false
      true -> true
    end
  end

  # ── IPv6 ───────────────────────────────────────────────────────────────
  defp public_ip?({0, 0, 0, 0, 0, 0, 0, 1}), do: false
  defp public_ip?({0, 0, 0, 0, 0, 0, 0, 0}), do: false

  # IPv4-mapped (::ffff:a.b.c.d) — unwrap and apply the IPv4 rules.
  defp public_ip?({0, 0, 0, 0, 0, 0xFFFF, x, y}), do: public_ip?(embedded_v4(x, y))

  # ::/96, the deprecated IPv4-compatible form: nothing legitimate lives here.
  defp public_ip?({0, 0, 0, 0, 0, 0, _, _}), do: false

  # NAT64 (64:ff9b::/96) and 6to4 (2002::/16) carry an IPv4 address inside
  # the IPv6 one. A host whose AAAA record is `64:ff9b::7f00:1` is a way to
  # name 127.0.0.1 through a translator, so the embedded address is judged by
  # the IPv4 rules. The local-use NAT64 prefix (64:ff9b:1::/48) is private.
  defp public_ip?({0x64, 0xFF9B, 0, 0, 0, 0, x, y}), do: public_ip?(embedded_v4(x, y))
  defp public_ip?({0x64, 0xFF9B, 1, _, _, _, _, _}), do: false
  defp public_ip?({0x2002, x, y, _, _, _, _, _}), do: public_ip?(embedded_v4(x, y))

  # Teredo (2001::/32), documentation (2001:db8::/32), discard-only (100::/64).
  defp public_ip?({0x2001, 0, _, _, _, _, _, _}), do: false
  defp public_ip?({0x2001, 0xDB8, _, _, _, _, _, _}), do: false
  defp public_ip?({0x100, 0, 0, 0, _, _, _, _}), do: false

  defp public_ip?({w, _, _, _, _, _, _, _}) do
    cond do
      # fc00::/7 unique local, fe80::/10 link-local, ff00::/8 multicast
      (w &&& 0xFE00) == 0xFC00 -> false
      (w &&& 0xFFC0) == 0xFE80 -> false
      (w &&& 0xFF00) == 0xFF00 -> false
      true -> true
    end
  end

  defp public_ip?(_), do: false

  defp embedded_v4(x, y), do: {x >>> 8, x &&& 0xFF, y >>> 8, y &&& 0xFF}
end
