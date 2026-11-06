# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiShared.UrlGuardTest do
  # Not async: it flips an application-wide switch for its duration.
  use ExUnit.Case, async: false

  # The one table for the one guard (gateway and delivery both call it).
  # IP literals only, so no DNS is needed.

  alias SukhiShared.UrlGuard

  # delivery's config/test.exs turns the guard off so Bypass (http://localhost)
  # can serve its tests; here it must be the real thing.
  setup do
    prev = Application.get_env(:sukhi_shared, :disable_url_guard)
    Application.put_env(:sukhi_shared, :disable_url_guard, false)

    on_exit(fn ->
      if is_nil(prev),
        do: Application.delete_env(:sukhi_shared, :disable_url_guard),
        else: Application.put_env(:sukhi_shared, :disable_url_guard, prev)
    end)
  end

  test "rejects loopback / private / link-local / metadata targets" do
    refute UrlGuard.safe?("https://127.0.0.1/inbox")
    refute UrlGuard.safe?("https://169.254.169.254/latest/meta-data/")
    refute UrlGuard.safe?("https://10.0.0.5/inbox")
    refute UrlGuard.safe?("https://192.168.1.10/inbox")
    refute UrlGuard.safe?("https://172.16.0.1/inbox")
    refute UrlGuard.safe?("https://100.64.0.1/inbox")
    refute UrlGuard.safe?("https://0.0.0.0/inbox")
    refute UrlGuard.safe?("https://[::1]/inbox")
  end

  test "public_host?/1 is the address rule alone, with no scheme policy" do
    assert UrlGuard.public_host?("1.1.1.1")
    refute UrlGuard.public_host?("127.0.0.1")
    refute UrlGuard.public_host?("10.0.0.5")
    refute UrlGuard.public_host?("::1")
  end

  test "public_addrs/1 hands back the checked addresses, and only if all are public" do
    assert {:ok, [_ | _] = addrs} = UrlGuard.public_addrs("1.1.1.1")
    assert {1, 1, 1, 1} in addrs
    assert :error = UrlGuard.public_addrs("127.0.0.1")
    assert :error = UrlGuard.public_addrs("::1")
    assert :error = UrlGuard.public_addrs("no-such-host.invalid")
  end

  test "public_addrs/1 follows the test switch, public_host?/1 does not" do
    Application.put_env(:sukhi_shared, :disable_url_guard, true)

    assert {:ok, _} = UrlGuard.public_addrs("127.0.0.1")
    refute UrlGuard.public_host?("127.0.0.1")
  end

  test "rejects non-https and malformed urls" do
    refute UrlGuard.safe?("http://1.1.1.1/inbox")
    refute UrlGuard.safe?("ftp://1.1.1.1/inbox")
    refute UrlGuard.safe?("file:///etc/passwd")
    refute UrlGuard.safe?("not a url")
    refute UrlGuard.safe?(nil)
  end

  test "allows a public https target" do
    assert UrlGuard.safe?("https://1.1.1.1/inbox")
  end

  test "rejects the 192.0 special /24s but not the rest of 192.0.0.0/16" do
    refute UrlGuard.safe?("https://192.0.0.5/inbox")
    refute UrlGuard.safe?("https://192.0.2.5/inbox")
    # 192.0.64.0/18 は Automattic(Gravatar) ── 弾くとリモートの avatar が
    # proxy で 502 になる(2026-09-22)。
    assert UrlGuard.safe?("https://192.0.80.239/inbox")
  end

  test "rejects IPv6 multicast, and IPv6 forms that carry an internal IPv4 address" do
    for host <- [
          # multicast
          "[ff02::1]",
          "[ff05::2]",
          # IPv4-mapped, NAT64 and 6to4 around 127.0.0.1 / 10.0.0.1
          "[::ffff:7f00:1]",
          "[64:ff9b::7f00:1]",
          "[64:ff9b::a00:1]",
          "[2002:7f00:1::]",
          "[2002:a00:1::1]",
          # local-use NAT64, Teredo, documentation, discard-only, ::/96
          "[64:ff9b:1::1]",
          "[2001:0:4136:e378:8000:63bf:3fff:fdd2]",
          "[2001:db8::1]",
          "[100::1]",
          "[::7f00:1]"
        ] do
      refute UrlGuard.safe?("https://#{host}/inbox"), "#{host} must be refused"
    end
  end

  test "an IPv6 literal that wraps a public IPv4 address, or is plain public, still passes" do
    assert UrlGuard.safe?("https://[64:ff9b::808:808]/inbox")
    assert UrlGuard.safe?("https://[2002:808:808::]/inbox")
    assert UrlGuard.safe?("https://[2606:4700:4700::1111]/inbox")
  end

  describe "DNS rebinding: the name is resolved once, and the answer is the one that is used" do
    # A resolver that answers a public address the first time it is asked and
    # 127.0.0.1 every time after. A guard that checks the name and then lets the
    # client resolve it again would connect to 127.0.0.1.
    setup do
      {:ok, calls} = Agent.start_link(fn -> [] end)

      resolver = fn host, family ->
        n = Agent.get_and_update(calls, fn l -> {length(l), [{host, family} | l]} end)

        case {family, n} do
          {:inet, 0} -> {:ok, [{93, 184, 216, 34}]}
          {:inet, _} -> {:ok, [{127, 0, 0, 1}]}
          {:inet6, _} -> {:error, :nxdomain}
        end
      end

      prev = Application.get_env(:sukhi_shared, :resolver)
      Application.put_env(:sukhi_shared, :resolver, resolver)

      on_exit(fn ->
        if is_nil(prev),
          do: Application.delete_env(:sukhi_shared, :resolver),
          else: Application.put_env(:sukhi_shared, :resolver, prev)
      end)

      %{calls: calls}
    end

    test "public_addrs/1 asks once per family and hands back the first answer", %{calls: calls} do
      assert {:ok, [{93, 184, 216, 34}]} = UrlGuard.public_addrs("rebind.example")

      assert [{~c"rebind.example", :inet}, {~c"rebind.example", :inet6}] =
               Agent.get(calls, & &1) |> Enum.reverse()
    end

    test "a name whose first answer is internal is refused outright" do
      Application.put_env(:sukhi_shared, :resolver, fn
        _host, :inet -> {:ok, [{10, 0, 0, 7}]}
        _host, :inet6 -> {:error, :nxdomain}
      end)

      assert :error = UrlGuard.public_addrs("internal.example")
    end

    test "a name with one internal address among public ones is refused" do
      Application.put_env(:sukhi_shared, :resolver, fn
        _host, :inet -> {:ok, [{93, 184, 216, 34}]}
        _host, :inet6 -> {:ok, [{0xFF02, 0, 0, 0, 0, 0, 0, 1}]}
      end)

      assert :error = UrlGuard.public_addrs("mixed.example")
    end
  end
end
