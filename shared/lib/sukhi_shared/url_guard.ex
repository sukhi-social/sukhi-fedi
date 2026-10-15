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
            host_safe?(host)

          _ ->
            false
        end
    end
  end

  def safe?(_), do: false

  defp host_safe?(host) do
    case resolve(host) do
      {:ok, [_ | _] = addrs} -> Enum.all?(addrs, &public_ip?/1)
      _ -> false
    end
  end

  defp resolve(host) do
    cl = String.to_charlist(host)

    case {:inet.getaddrs(cl, :inet), :inet.getaddrs(cl, :inet6)} do
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
  defp public_ip?({0, 0, 0, 0, 0, 0xFFFF, x, y}),
    do: public_ip?({x >>> 8, x &&& 0xFF, y >>> 8, y &&& 0xFF})

  defp public_ip?({w, _, _, _, _, _, _, _}) do
    cond do
      (w &&& 0xFE00) == 0xFC00 -> false
      (w &&& 0xFFC0) == 0xFE80 -> false
      true -> true
    end
  end

  defp public_ip?(_), do: false
end
