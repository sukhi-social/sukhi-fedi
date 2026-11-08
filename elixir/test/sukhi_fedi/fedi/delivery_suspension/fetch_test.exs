# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Fedi.DeliverySuspension.FetchTest do
  use ExUnit.Case, async: true

  alias SukhiFedi.Fedi.DeliverySuspension.Fetch
  alias SukhiFedi.SuspensionNet, as: Net

  @url "https://a.example/suspensions/1"

  defp get(web, kind \\ :activity, opts \\ []),
    do: Fetch.get(@url, kind, Keyword.put(opts, :http, Net.http(web)))

  test "a document comes back with its etag and the URL it came from" do
    web = %{
      @url =>
        {:ok,
         %{
           status: 200,
           headers: %{"content-type" => ["application/activity+json"], "etag" => ["\"v1\""]},
           body: ~s({"a":1})
         }}
    }

    assert {:ok, %{document: %{"a" => 1}, etag: "\"v1\"", url: @url}} = get(web)
  end

  test "Accept is asked by kind, and no signature is sent" do
    get(%{@url => Net.json(%{})})
    assert_received {:requested, @url, headers}
    assert {"accept", accept} = List.keyfind(headers, "accept", 0)
    assert accept =~ "application/activity+json"
    assert accept =~ "application/ld+json"
    refute List.keymember?(headers, "signature", 0)
    refute List.keymember?(headers, "authorization", 0)

    get(%{@url => Net.json(%{}, type: "application/jrd+json")}, :webfinger)
    assert_received {:requested, @url, headers}
    assert {"accept", "application/jrd+json" <> _} = List.keyfind(headers, "accept", 0)
  end

  test "either form of the type is taken, with parameters; a page is not" do
    for type <- [
          "application/activity+json",
          "application/ld+json; profile=\"https://www.w3.org/ns/activitystreams\"",
          "application/jrd+json",
          "Application/JSON; charset=utf-8"
        ] do
      assert {:ok, _} = get(%{@url => Net.json(%{}, type: type)})
    end

    assert {:error, :bad_document} = get(%{@url => Net.json(%{}, type: "text/html")})
  end

  test "a 304 is only 'not changed', and only when asked with an etag" do
    web = %{@url => Net.status(304)}
    assert :not_modified = get(web, :activity, etag: "\"v1\"")
    assert_received {:requested, @url, headers}
    assert {"if-none-match", "\"v1\""} = List.keyfind(headers, "if-none-match", 0)

    # nobody asked: a 304 is not an answer
    assert {:error, :unavailable} = get(web)
  end

  test "failures are named by what they mean" do
    assert {:error, :unauthorized} = get(%{@url => Net.status(401)})
    assert {:error, :unauthorized} = get(%{@url => Net.status(403)})
    assert {:error, :gone} = get(%{@url => Net.status(404)})
    assert {:error, :gone} = get(%{@url => Net.status(410)})
    assert {:error, :unavailable} = get(%{@url => Net.status(500)})
    assert {:error, :unavailable} = get(%{@url => Net.status(503)})
    assert {:error, :unavailable} = get(%{@url => Net.status(429)})
    assert {:error, :unavailable} = get(%{@url => Net.down()})
    assert {:error, :too_large} = get(%{@url => {:error, :document_too_large}})
    assert {:error, :unsafe_target} = get(%{@url => {:error, :unsafe_address}})
  end

  test "a body that is not an object, too deep, or too big is a bad document" do
    assert {:error, :bad_document} = get(%{@url => Net.json([1, 2])})
    deep = Enum.reduce(1..9, %{}, fn _, acc -> %{"n" => acc} end)
    assert {:error, :bad_document} = get(%{@url => Net.json(deep)})

    big =
      {:ok,
       %{
         status: 200,
         headers: %{"content-type" => ["application/json"]},
         body: ~s({"x":") <> String.duplicate("a", 70_000) <> ~s("})
       }}

    assert {:error, :bad_document} = get(%{@url => big})

    assert {:error, :bad_document} =
             get(%{
               @url =>
                 {:ok,
                  %{status: 200, headers: %{"content-type" => ["application/json"]}, body: "{"}}
             })
  end

  test "only https, and never anything else" do
    assert {:error, :unsafe_target} =
             Fetch.get("http://a.example/x", :activity, http: Net.http(%{}))

    assert {:error, :unsafe_target} =
             Fetch.get("ftp://a.example/x", :activity, http: Net.http(%{}))

    refute_received {:requested, _, _}
  end

  describe "redirects" do
    test "are followed, up to three, and each hop is checked" do
      web = %{
        @url => Net.redirect("https://b.example/1"),
        "https://b.example/1" => Net.redirect("/2"),
        "https://b.example/2" => Net.json(%{"ok" => true})
      }

      assert {:ok, %{document: %{"ok" => true}, url: "https://b.example/2"}} = get(web)
    end

    test "a fourth hop is not taken" do
      web = %{
        @url => Net.redirect("https://b.example/1"),
        "https://b.example/1" => Net.redirect("/2"),
        "https://b.example/2" => Net.redirect("/3"),
        "https://b.example/3" => Net.redirect("/4"),
        "https://b.example/4" => Net.json(%{})
      }

      assert {:error, :unavailable} = get(web)
    end

    test "a hop to http, or with no Location, ends it" do
      assert {:error, :unsafe_target} = get(%{@url => Net.redirect("http://b.example/")})
      assert {:error, :unavailable} = get(%{@url => Net.status(302)})
    end
  end
end
