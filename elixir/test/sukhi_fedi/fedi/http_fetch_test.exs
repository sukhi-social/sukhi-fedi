# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Fedi.HttpFetchTest do
  # Not async: the setup flips the application-wide `:disable_url_guard` switch.
  use ExUnit.Case, async: false

  alias SukhiFedi.Fedi.HttpFetch

  # A loopback server we control: one route streams more than the 1 MiB
  # cap, one a tiny JSON document, one echoes the Host header. No network,
  # no DB. A loopback target is exactly what the address guard refuses, so
  # `setup` turns the guard off (the test-env switch) except where a test
  # turns it back on to check the refusal.
  defmodule Server do
    import Plug.Conn

    def init(opts), do: opts

    def call(%Plug.Conn{path_info: ["huge"]} = conn, _opts) do
      # 2 MiB — past HttpFetch's 1 MiB cap.
      conn
      |> put_resp_content_type("application/activity+json")
      |> send_resp(200, :binary.copy("x", 2 * 1024 * 1024))
    end

    def call(%Plug.Conn{path_info: ["host"]} = conn, _opts) do
      send_resp(conn, 200, conn |> get_req_header("host") |> List.first())
    end

    def call(%Plug.Conn{path_info: ["slow-start"]} = conn, _opts) do
      Process.sleep(1_000)
      send_resp(conn, 200, "late")
    end

    def call(%Plug.Conn{path_info: ["tiny"]} = conn, _opts) do
      conn
      |> put_resp_content_type("application/activity+json")
      |> send_resp(200, ~s({"id":"https://example.test/1"}))
    end
  end

  setup do
    prev = Application.get_env(:sukhi_shared, :disable_url_guard)
    Application.put_env(:sukhi_shared, :disable_url_guard, true)
    {:ok, server} = Bandit.start_link(plug: Server, scheme: :http, port: 0, ip: {127, 0, 0, 1})
    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)

    on_exit(fn ->
      Process.exit(server, :normal)

      if is_nil(prev),
        do: Application.delete_env(:sukhi_shared, :disable_url_guard),
        else: Application.put_env(:sukhi_shared, :disable_url_guard, prev)
    end)

    %{base: "http://127.0.0.1:#{port}", port: port}
  end

  test "an over-limit response body yields {:error, :document_too_large}", %{base: base} do
    assert {:error, :document_too_large} =
             HttpFetch.capped_get("#{base}/huge")
  end

  test "a small response body passes through as the raw binary", %{base: base} do
    assert {:ok, %Req.Response{status: 200, body: body}} =
             HttpFetch.capped_get("#{base}/tiny")

    # into: streams raw bytes; Req does not auto-decode under the collector.
    assert body == ~s({"id":"https://example.test/1"})
  end

  test "connects to the address it resolved and sends the host name", %{port: port} do
    # `localhost` is resolved once, to loopback, and the connection goes to
    # that address; the Host header and the TLS name stay the name we were given.
    assert {:ok, %Req.Response{status: 200, body: body}} =
             HttpFetch.capped_get("http://localhost:#{port}/host")

    assert body == "localhost:#{port}"
  end

  test "refuses a host that resolves to an internal address", %{port: port} do
    Application.put_env(:sukhi_shared, :disable_url_guard, false)

    assert {:error, :unsafe_address} = HttpFetch.capped_get("http://127.0.0.1:#{port}/tiny")
    assert {:error, :unsafe_address} = HttpFetch.capped_get("http://localhost:#{port}/tiny")
    assert {:error, :unsafe_address} = HttpFetch.capped_post("https://10.0.0.5/inbox")
  end

  test "a host that does not resolve is refused, not retried by name", _ do
    assert {:error, :unsafe_address} = HttpFetch.capped_get("http://no-such-host.invalid/x")
  end

  test "a response that does not start in time is a timeout error", %{base: base} do
    assert {:error, %Req.TransportError{reason: :timeout}} =
             HttpFetch.capped_get("#{base}/slow-start", receive_timeout: 100)
  end

  test "an option it does not act on is refused, not ignored", %{base: base} do
    assert_raise ArgumentError, fn -> HttpFetch.capped_get("#{base}/tiny", redirect: true) end
  end

  describe "JSON nesting depth, checked on the bytes" do
    test "an ordinary document passes" do
      assert {:ok, %{"a" => [1, %{"b" => []}]}} = HttpFetch.decode_json(~s({"a":[1,{"b":[]}]}))
    end

    test "the limit is on levels, not on bytes" do
      ok = String.duplicate("[", 32) <> String.duplicate("]", 32)
      too_deep = String.duplicate("[", 33) <> String.duplicate("]", 33)

      assert HttpFetch.json_depth_ok?(ok)
      refute HttpFetch.json_depth_ok?(too_deep)
      assert {:error, :json_too_deep} = HttpFetch.decode_json(too_deep)
    end

    test "an unclosed megabyte of brackets is refused without decoding" do
      refute HttpFetch.json_depth_ok?(String.duplicate("[", 1024 * 1024))
    end

    test "brackets inside strings are not levels, escaped quotes do not end a string" do
      in_string = ~s({"a":") <> String.duplicate("[", 100) <> ~s("})
      # `\"` is an escaped quote: the string goes on, so these 40 are still text.
      escaped = ~S({"a":"\") <> String.duplicate("[", 40) <> ~S("})

      assert HttpFetch.json_depth_ok?(in_string)
      assert HttpFetch.json_depth_ok?(escaped)
      assert {:ok, %{"a" => "\"" <> _}} = HttpFetch.decode_json(escaped)
      assert {:ok, _} = HttpFetch.decode_json(in_string)
    end

    test "siblings do not add up" do
      many = "[" <> String.duplicate("[],", 1000) <> "[]]"
      assert HttpFetch.json_depth_ok?(many)
    end
  end
end
