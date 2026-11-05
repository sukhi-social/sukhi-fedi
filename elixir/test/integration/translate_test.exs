# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Integration.TranslateTest do
  use SukhiFedi.IntegrationCase, async: false

  @moduletag :integration

  alias SukhiFedi.Notes
  alias SukhiFedi.Schema.{Account, Follow}
  alias SukhiFedi.Translate
  alias SukhiFedi.Translate.Key

  @key "0c1d2e3f-4a5b-6c7d-8e9f-a0b1c2d3e4f5"

  setup do
    keys = [:libretranslate_url, :translate_req_options, :hot_cache]
    prev = for k <- keys, into: %{}, do: {k, Application.get_env(:sukhi_fedi, k)}

    {:ok, _} = Application.ensure_all_started(:req)
    Application.put_env(:sukhi_fedi, :libretranslate_url, "http://libretranslate:5000")
    Application.put_env(:sukhi_fedi, :translate_req_options, plug: {Req.Test, __MODULE__}, retry: false)

    test = self()

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      body = JSON.decode!(raw)
      send(test, {:engine, conn.host, Plug.Conn.get_req_header(conn, "authorization"), body})

      out =
        if conn.host == "libretranslate",
          do: %{"translatedText" => Enum.map(body["q"], &("[ja]" <> &1 <> "<script>alert(1)</script>")), "detectedLanguage" => [%{"language" => "ko"}]},
          else: %{"translations" => Enum.map(body["text"], &%{"detected_source_language" => "KO", "text" => "[deepl]" <> &1})}

      conn |> Plug.Conn.put_resp_content_type("application/json") |> Plug.Conn.send_resp(200, JSON.encode!(out))
    end)

    on_exit(fn ->
      for {k, v} <- prev do
        if v == nil, do: Application.delete_env(:sukhi_fedi, k), else: Application.put_env(:sukhi_fedi, k, v)
      end
    end)

    :ok
  end

  defp account!(username, attrs \\ %{}) do
    %Account{username: username, display_name: username, summary: ""} |> struct(attrs) |> Repo.insert!()
  end

  defp deepl_user!(username) do
    a = account!(username)
    {:ok, sealed, hint} = Key.seal(@key, a.id)
    a |> Ecto.Changeset.change(translate_engine: "deepl", translate_deepl_key: sealed, translate_deepl_key_hint: hint) |> Repo.update!()
  end

  defp note!(author, text, visibility, extra \\ %{}) do
    {:ok, note} = Notes.create_status(author, Map.merge(%{"status" => text, "visibility" => visibility}, extra))
    note
  end

  defp follow!(follower, author) do
    uri = "https://#{Application.get_env(:sukhi_fedi, :domain, "localhost:4000")}/users/#{follower.username}"
    Repo.insert!(%Follow{follower_uri: uri, followee_id: author.id, state: "accepted"})
  end

  test "a public post is translated by the server's own translator, and what comes back is sanitised" do
    author = account!("tr_author")
    reader = account!("tr_reader")
    note = note!(author, "안녕하세요", "public", %{"spoiler_text" => "스포"})

    assert {:ok, out} = Translate.status(reader, note.id, "ja")
    assert out.provider == "LibreTranslate"
    assert out.detected_source_language == "ko"
    assert out.content =~ "[ja]"
    refute out.content =~ "script"
    assert out.spoiler_text =~ "[ja]"
    assert out.media_attachments == [] and out.poll == nil

    assert_receive {:engine, "libretranslate", [], %{"q" => [html, _spoiler], "target" => "ja", "format" => "html"}}
    assert html =~ "안녕하세요"
  end

  test "someone who may not see the post cannot have it translated" do
    author = account!("tr_author2")
    stranger = account!("tr_stranger")
    note = note!(author, "秘密", "followers")

    assert {:error, :not_found} = Translate.status(stranger, note.id, "en")
    refute_received {:engine, _, _, _}
  end

  test "a direct message is not sent to any engine, not even for its participants" do
    alice = account!("tr_dm_alice")
    bob = account!("tr_dm_bob")
    dm = note!(alice, "@#{bob.username} 안녕", "direct")

    assert {:error, :not_translatable} = Translate.status(bob, dm.id, "ja")
    assert {:error, :not_translatable} = Translate.status(alice, dm.id, "ja")
    refute_received {:engine, _, _, _}
  end

  test "a person's own DeepL key is used for a public post, and the provider says DeepL" do
    author = account!("tr_author3")
    reader = deepl_user!("tr_deepl_reader")
    note = note!(author, "안녕", "public")

    assert {:ok, %{provider: "DeepL", content: "[deepl]" <> _}} = Translate.status(reader, note.id, "ja")
    assert_receive {:engine, "api.deepl.com", ["DeepL-Auth-Key " <> @key], _}
  end

  test "a followers-only post never goes to DeepL: it goes to the server's translator, and says so" do
    author = account!("tr_author4")
    reader = deepl_user!("tr_deepl_follower")
    follow!(reader, author)
    note = note!(author, "안녕", "followers")

    assert {:ok, %{provider: "LibreTranslate"}} = Translate.status(reader, note.id, "ja")
    assert_receive {:engine, "libretranslate", _, _}
    refute_received {:engine, "api.deepl.com", _, _}
  end

  test "the engine does not change by itself: with no translator of the server's own, the answer is `disabled`" do
    Application.delete_env(:sukhi_fedi, :libretranslate_url)
    author = account!("tr_author5")
    reader = account!("tr_reader5")
    note = note!(author, "안녕", "public")

    assert {:error, :disabled} = Translate.status(reader, note.id, "ja")
    refute_received {:engine, _, _, _}
  end

  test "a key that cannot be opened is `no_key`, never a fallback to another engine" do
    author = account!("tr_author6")
    reader = deepl_user!("tr_reader6")
    note = note!(author, "안녕", "public")

    # A sealed key copied from another account does not open on this one.
    {:ok, foreign, _} = Key.seal(@key, reader.id + 1000)
    reader |> Ecto.Changeset.change(translate_deepl_key: foreign) |> Repo.update!()

    assert {:error, :no_key} = Translate.status(reader, note.id, "ja")
    refute_received {:engine, _, _, _}
  end

  test "the target must be one we translate into; a post that is too long is refused" do
    author = account!("tr_author7")
    reader = account!("tr_reader7")
    note = note!(author, "안녕", "public")
    long = note!(author, String.duplicate("가", 3_001), "public")

    assert {:error, :unsupported_language} = Translate.status(reader, note.id, "fr")
    assert {:error, :unsupported_language} = Translate.status(reader, note.id, nil)
    assert {:error, :too_long} = Translate.status(reader, long.id, "ja")
    refute_received {:engine, _, _, _}
  end

  test "a post many people ask for is translated once; one person's own key is not shared" do
    Application.put_env(:sukhi_fedi, :hot_cache, translate: 60)
    author = account!("tr_author8")
    one = account!("tr_one")
    two = account!("tr_two")
    own = deepl_user!("tr_own")
    note = note!(author, "캐시 테스트 #{System.unique_integer([:positive])}", "public")

    assert {:ok, _} = Translate.status(one, note.id, "ja")
    assert_receive {:engine, "libretranslate", _, _}
    assert {:ok, _} = Translate.status(two, note.id, "ja")
    refute_received {:engine, "libretranslate", _, _}

    # Someone using their own key makes their own call, and it is kept for them alone.
    assert {:ok, %{provider: "DeepL"}} = Translate.status(own, note.id, "ja")
    assert_receive {:engine, "api.deepl.com", _, _}
  end

  test "an engine that is busy answers busy, and the failure is not cached" do
    Application.put_env(:sukhi_fedi, :hot_cache, translate: 60)
    author = account!("tr_author9")
    reader = account!("tr_reader9")
    note = note!(author, "일시 오류 #{System.unique_integer([:positive])}", "public")

    Req.Test.stub(__MODULE__, fn conn -> Plug.Conn.send_resp(conn, 429, "{}") end)
    assert {:error, :busy} = Translate.status(reader, note.id, "ja")

    Req.Test.stub(__MODULE__, fn conn ->
      conn |> Plug.Conn.put_resp_content_type("application/json") |> Plug.Conn.send_resp(200, JSON.encode!(%{"translatedText" => ["<p>ok</p>"]}))
    end)

    assert {:ok, %{content: "<p>ok</p>"}} = Translate.status(reader, note.id, "ja")
  end

  test "auto is refused for an account that has not turned it on, before anything about the post is read" do
    author = account!("tr_author10")
    reader = account!("tr_reader10")
    # Even a post this reader may not see answers `auto_off`, not `not_found`.
    hidden = note!(author, "秘密 #{System.unique_integer([:positive])}", "followers")
    open = note!(author, "공개 #{System.unique_integer([:positive])}", "public")

    assert {:error, :auto_off} = Translate.status(reader, open.id, "ja", auto: true)
    assert {:error, :auto_off} = Translate.status(reader, hidden.id, "ja", auto: true)
    refute_received {:engine, _, _, _}

    # A press by the same account is unaffected.
    assert {:ok, _} = Translate.status(reader, open.id, "ja")
  end

  test "auto works for someone who turned it on, with the same engine rules as a press" do
    author = account!("tr_author11")
    reader = account!("tr_reader11", %{translate_auto: true})
    note = note!(author, "자동 #{System.unique_integer([:positive])}", "public")

    assert {:ok, %{provider: "LibreTranslate"}} = Translate.status(reader, note.id, "ja", auto: true)
    assert_receive {:engine, "libretranslate", _, _}

    dm = note!(author, "@#{reader.username} 안녕", "direct")
    assert {:error, :not_translatable} = Translate.status(reader, dm.id, "ja", auto: true)
  end

  test "a post behind a content warning is not sent by auto, but a press may open it" do
    author = account!("tr_author12")
    reader = account!("tr_reader12", %{translate_auto: true})
    note = note!(author, "본문 #{System.unique_integer([:positive])}", "public", %{"spoiler_text" => "주의"})

    assert {:error, :not_translatable} = Translate.status(reader, note.id, "ja", auto: true)
    refute_received {:engine, _, _, _}

    assert {:ok, _} = Translate.status(reader, note.id, "ja")
    assert_receive {:engine, "libretranslate", _, _}
  end
end
