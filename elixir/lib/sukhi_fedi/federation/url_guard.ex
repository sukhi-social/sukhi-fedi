# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Federation.UrlGuard do
  @moduledoc """
  SSRF guard for outbound requests whose host comes from attacker
  controlled data (e.g. the `host` of a WebFinger handle).

  `safe?/1` requires `https` and refuses any host that resolves to a
  loopback / private / link-local / unique-local / CGNAT / unspecified /
  multicast address. DNS is resolved here and every returned address is
  checked, so a name that resolves to an internal IP is rejected too.

  (The bun/fedify document loader already guards the actor/note *fetch*
  path; this covers the Elixir-side WebFinger fetch, which does not go
  through it.)
  """

  import Bitwise

  # The delivery node carries its own copy (`SukhiDelivery.Federation.UrlGuard`,
  # a separate deployable). Change a rule in both, and the table in both
  # `UrlGuardTest`s: they are the same list on purpose.

  @spec safe?(term()) :: boolean()
  def safe?(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: "https", host: host} when is_binary(host) and host != "" ->
        host_safe?(host)

      _ ->
        false
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
      # 192.0.0.0/24 (IETF protocol assignments) と 192.0.2.0/24 (TEST-NET-1)。
      # `b == 0` で 192.0.0.0/16 を丸ごと弾いていたが、192.0.64.0/18 は
      # Automattic(Gravatar) の普通の公開空間で、リモートの avatar がそこに
      # 居ると `/proxy/avatar` が 502 になっていた(2026-09-22)。
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
