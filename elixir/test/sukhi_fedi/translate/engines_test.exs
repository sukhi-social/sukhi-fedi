# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Translate.EnginesTest do
  use ExUnit.Case, async: false

  alias SukhiFedi.Translate.{DeepL, LibreTranslate}

  @key "0c1d2e3f-4a5b-6c7d-8e9f-a0b1c2d3e4f5"

  # `mix test --no-start` (make test-elixir) leaves Req's own processes (Req.Test) down.
  setup_all do
    {:ok, _} = Application.ensure_all_started(:req)
    :ok
  end

  setup do
    prev = for k <- [:libretranslate_url, :libretranslate_api_key, :translate_req_options], into: %{}, do: {k, Application.get_env(:sukhi_fedi, k)}

    Application.put_env(:sukhi_fedi, :translate_req_options, plug: {Req.Test, __MODULE__}, retry: false)

    on_exit(fn ->
      for {k, v} <- prev do
        if v == nil, do: Application.delete_env(:sukhi_fedi, k), else: Application.put_env(:sukhi_fedi, k, v)
      end
    end)

    :ok
  end

  defp stub(fun), do: Req.Test.stub(__MODULE__, fun)

  defp reply(conn, status, body) do
    conn |> Plug.Conn.put_resp_content_type("application/json") |> Plug.Conn.send_resp(status, JSON.encode!(body))
  end

  describe "LibreTranslate" do
    setup do
      Application.put_env(:sukhi_fedi, :libretranslate_url, "http://libretranslate:5000/")
      Application.delete_env(:sukhi_fedi, :libretranslate_api_key)
    end

    test "is configured only when there is a URL" do
      assert LibreTranslate.configured?()
      Application.delete_env(:sukhi_fedi, :libretranslate_url)
      refute LibreTranslate.configured?()
      Application.put_env(:sukhi_fedi, :libretranslate_url, "")
      refute LibreTranslate.configured?()
    end

    test "sends the texts as HTML to the operator's URL and reads the answer" do
      test = self()

      stub(fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test, {:req, conn.host, conn.port, conn.request_path, JSON.decode!(raw)})
        reply(conn, 200, %{"translatedText" => ["<p>こんにちは</p>", "ネタバレ"], "detectedLanguage" => [%{"language" => "ko", "confidence" => 90}]})
      end)

      assert {:ok, %{texts: ["<p>こんにちは</p>", "ネタバレ"], detected: "ko"}} =
               LibreTranslate.translate(["<p>안녕</p>", "스포"], nil, "ja")

      assert_receive {:req, "libretranslate", 5000, "/translate", body}
      assert body == %{"q" => ["<p>안녕</p>", "스포"], "source" => "auto", "target" => "ja", "format" => "html"}
    end

    test "a single text answers a string and a detected-language map" do
      stub(fn conn -> reply(conn, 200, %{"translatedText" => "hi", "detectedLanguage" => %{"language" => "ja"}}) end)
      assert {:ok, %{texts: ["hi"], detected: "ja"}} = LibreTranslate.translate(["こんにちは"], "ja", "en")
    end

    test "the API key, when there is one, rides in the body" do
      Application.put_env(:sukhi_fedi, :libretranslate_api_key, "lt-secret")
      test = self()

      stub(fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test, {:body, JSON.decode!(raw)})
        reply(conn, 200, %{"translatedText" => "x"})
      end)

      assert {:ok, _} = LibreTranslate.translate(["a"], nil, "en")
      assert_receive {:body, %{"api_key" => "lt-secret"}}
    end

    test "failures are atoms" do
      for {status, reason} <- [{400, :unsupported_language}, {429, :busy}, {403, :engine_rejected}, {401, :engine_rejected}, {500, :engine_unavailable}] do
        stub(fn conn -> reply(conn, status, %{"error" => "no"}) end)
        assert {:error, ^reason} = LibreTranslate.translate(["a"], nil, "en"), "status #{status}"
      end

      stub(fn conn -> Req.Test.transport_error(conn, :econnrefused) end)
      assert {:error, :engine_unavailable} = LibreTranslate.translate(["a"], nil, "en")
    end
  end

  describe "DeepL" do
    test "a Free key goes to the Free host, a Pro key to the Pro host, in a header and nowhere else" do
      test = self()

      stub(fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test, {:req, conn.host, conn.request_path, Plug.Conn.get_req_header(conn, "authorization"), raw})
        reply(conn, 200, %{"translations" => [%{"detected_source_language" => "KO", "text" => "<p>こんにちは</p>"}]})
      end)

      assert {:ok, %{texts: ["<p>こんにちは</p>"], detected: "ko"}} = DeepL.translate(["<p>안녕</p>"], nil, "ja", @key <> ":fx")
      assert_receive {:req, "api-free.deepl.com", "/v2/translate", ["DeepL-Auth-Key " <> _], raw}
      refute String.contains?(raw, @key)
      assert %{"text" => ["<p>안녕</p>"], "target_lang" => "JA", "tag_handling" => "html"} = JSON.decode!(raw)
      refute Map.has_key?(JSON.decode!(raw), "source_lang")

      assert {:ok, _} = DeepL.translate(["a"], "ko", "en", @key)
      assert_receive {:req, "api.deepl.com", "/v2/translate", ["DeepL-Auth-Key " <> @key], raw}
      assert %{"target_lang" => "EN-US", "source_lang" => "KO"} = JSON.decode!(raw)
    end

    test "failures are atoms, and never carry the key" do
      for {status, reason} <- [{403, :key_rejected}, {456, :quota}, {429, :busy}, {400, :unsupported_language}, {503, :engine_unavailable}] do
        stub(fn conn -> reply(conn, status, %{"message" => "no"}) end)
        result = DeepL.translate(["a"], nil, "ja", @key)
        assert result == {:error, reason}, "status #{status}"
        refute inspect(result) =~ @key
      end

      stub(fn conn -> Req.Test.transport_error(conn, :timeout) end)
      assert {:error, :engine_unavailable} = DeepL.translate(["a"], nil, "ja", @key)
    end
  end
end
