# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiShared.DeliverySuspension.Origin do
  @moduledoc """
  The one place a URL becomes an **origin** for FEP-f799 matching, and the
  strict front door for an origin a notice names (`targetOrigin`).

  An origin is `https://host` or `https://host:port`. Two spellings of the
  same origin must come out as the same string, and two different origins must
  never collide, because a wrong collision silences someone (or fails to).
  So this module does not hand the string to a URL parser and trust what comes
  back: it first decides whether the string is a form we accept at all, and
  only then normalizes it.

  Refused (`:error`):

    * anything but `https`, an empty host, userinfo, query, fragment, a path
      other than none or `/` (for `normalize/1`), a `\\`, an IPv6 zone id;
    * an IPv4 spelled any way but four plain decimal octets — shorthand
      (`127.1`), integer (`2130706433`), octal, hex (`0x7f.1`), leading zeros;
    * an empty label (`a..b`), a name longer than 253 bytes, a port that is
      not `1..65535` in plain digits;
    * a name that is not valid under **IDNA 2008, strictly** (no UTS #46
      mapping, no transitional processing): `faß.example` is
      `xn--fa-hia.example`, never `fass.example`.

  Normalized: scheme and host lower-cased, the default port 443 dropped, a
  trailing `/` allowed, IPv6 written the RFC 5952 way. **A trailing dot on a
  DNS name is kept** — `social.example.` and `social.example` are different
  names to a resolver and to us.

  Matching is the only use: a signed document is never rewritten with the
  normalized form.

  Pure, no I/O. `:error` means "do not match" — the caller's answer to
  anything it cannot read is to deliver as usual.
  """

  @max_host_bytes 253

  @type t :: String.t()

  @doc """
  Normalize an origin string (`"https://Social.Example:443/"` →
  `"https://social.example"`). Refuses anything with a path, query or fragment.
  """
  @spec normalize(term()) :: {:ok, t()} | :error
  def normalize(value) when is_binary(value) do
    with {:ok, authority, rest} <- split(value),
         true <- rest in ["", "/"],
         {:ok, origin} <- from_authority(authority) do
      {:ok, origin}
    else
      _ -> :error
    end
  end

  def normalize(_), do: :error

  @doc """
  The origin of the URL a delivery goes to (`https://social.example/users/a/inbox`
  → `"https://social.example"`). Path and query are ignored; the host rules
  are the same as `normalize/1`.
  """
  @spec of_delivery_url(term()) :: {:ok, t()} | :error
  def of_delivery_url(value) when is_binary(value) do
    with {:ok, authority, _rest} <- split(value),
         {:ok, origin} <- from_authority(authority) do
      {:ok, origin}
    else
      _ -> :error
    end
  end

  def of_delivery_url(_), do: :error

  # ── splitting ────────────────────────────────────────────────────────────

  # `https://` (any case), then the authority up to the first `/`, `?` or `#`.
  defp split(<<scheme::binary-size(8), rest::binary>>) do
    if String.downcase(scheme) == "https://" do
      {authority, tail} = take_authority(rest, <<>>)
      if authority == "", do: :error, else: {:ok, authority, tail}
    else
      :error
    end
  end

  defp split(_), do: :error

  defp take_authority(<<>>, acc), do: {acc, ""}
  defp take_authority(<<c, _::binary>> = tail, acc) when c in [?/, ?\?, ?#], do: {acc, tail}
  defp take_authority(<<c, rest::binary>>, acc), do: take_authority(rest, <<acc::binary, c>>)

  # ── authority → origin ───────────────────────────────────────────────────

  defp from_authority(authority) do
    cond do
      String.contains?(authority, ["@", "\\"]) -> :error
      String.starts_with?(authority, "[") -> ipv6_authority(authority)
      true -> name_authority(authority)
    end
  end

  defp ipv6_authority("[" <> rest) do
    with [inner, after_bracket] <- String.split(rest, "]", parts: 2),
         false <- String.contains?(inner, "%"),
         {:ok, address} <- :inet.parse_ipv6strict_address(String.to_charlist(inner)),
         {:ok, port} <- port_after(after_bracket) do
      {:ok, build("[" <> format_ipv6(address) <> "]", port)}
    else
      _ -> :error
    end
  end

  defp port_after(""), do: {:ok, 443}
  defp port_after(":" <> digits), do: port(digits)
  defp port_after(_), do: :error

  defp name_authority(authority) do
    {host, port} =
      case String.split(authority, ":") do
        [host] -> {host, {:ok, 443}}
        [host, digits] -> {host, port(digits)}
        _ -> {nil, :error}
      end

    with {:ok, port} <- port,
         true <- is_binary(host) and host != "",
         {:ok, host} <- host_name(host) do
      {:ok, build(host, port)}
    else
      _ -> :error
    end
  end

  defp port(digits) do
    with true <- digits =~ ~r/\A[1-9][0-9]{0,4}\z/,
         {port, ""} <- Integer.parse(digits),
         true <- port <= 65_535 do
      {:ok, port}
    else
      _ -> :error
    end
  end

  defp build(host, 443), do: "https://" <> host
  defp build(host, port), do: "https://" <> host <> ":" <> Integer.to_string(port)

  # ── host names ───────────────────────────────────────────────────────────

  # An IPv4 literal, or a DNS name that is not secretly a number.
  defp host_name(host) do
    host = String.downcase(host)

    {bare, dot} =
      if String.ends_with?(host, "."),
        do: {String.trim_trailing(host, "."), "."},
        else: {host, ""}

    cond do
      bare == "" -> :error
      numeric_tail?(bare) -> ipv4(bare, dot)
      true -> dns_name(bare, dot)
    end
  end

  # WHATWG's "ends in a number": if the last label is all digits or `0x…`,
  # the host is an IPv4 spelling, and only the plain four-octet one is taken.
  defp numeric_tail?(bare) do
    last = bare |> String.split(".") |> List.last()
    last =~ ~r/\A[0-9]+\z/ or last =~ ~r/\A0x[0-9a-f]*\z/
  end

  defp ipv4(bare, ""), do: strict_quad(bare)
  # `127.0.0.1.` — a dotted quad with a trailing dot is a name nobody wrote on purpose.
  defp ipv4(_bare, _dot), do: :error

  defp strict_quad(bare) do
    octets = String.split(bare, ".")

    if length(octets) == 4 and Enum.all?(octets, &octet?/1), do: {:ok, bare}, else: :error
  end

  defp octet?(s), do: s =~ ~r/\A(0|[1-9][0-9]{0,2})\z/ and String.to_integer(s) <= 255

  defp dns_name(bare, dot) do
    labels = String.split(bare, ".")

    with false <- Enum.any?(labels, &(&1 == "")),
         {:ok, ascii} <- idna2008(bare),
         true <- byte_size(ascii) <= @max_host_bytes do
      {:ok, ascii <> dot}
    else
      _ -> :error
    end
  end

  # `uts46: false` is IDNA 2008 as written (RFC 5891-5895): a U-label must
  # already be in its final form (so an upper-case or width-variant letter is
  # refused rather than mapped), an A-label is decoded and re-checked, and
  # `ß` stays `ß`.
  defp idna2008(name) do
    ascii =
      name
      |> String.to_charlist()
      |> :idna.encode(uts46: false, std3_rules: false, transitional: false)
      |> List.to_string()

    {:ok, String.downcase(ascii)}
  catch
    _kind, _reason -> :error
  end

  # ── IPv6, RFC 5952 ───────────────────────────────────────────────────────

  # Lower-case hex without leading zeros; the longest run of two or more zero
  # groups becomes `::` (the first, if two are equally long); a lone zero group
  # is written `0`.
  defp format_ipv6(address) do
    groups = Tuple.to_list(address)

    case longest_zero_run(groups) do
      nil ->
        join(groups)

      {start, len} ->
        head = groups |> Enum.take(start) |> join()
        tail = groups |> Enum.drop(start + len) |> join()
        head <> "::" <> tail
    end
  end

  defp join(groups),
    do: groups |> Enum.map(&Integer.to_string(&1, 16)) |> Enum.join(":") |> String.downcase()

  defp longest_zero_run(groups) do
    groups
    |> Enum.with_index()
    |> Enum.chunk_by(fn {g, _} -> g == 0 end)
    |> Enum.filter(fn [{g, _} | _] = run -> g == 0 and length(run) >= 2 end)
    |> Enum.reduce(nil, fn run, best ->
      [{_, start} | _] = run

      case best do
        {_, best_len} when best_len >= length(run) -> best
        _ -> {start, length(run)}
      end
    end)
  end
end
