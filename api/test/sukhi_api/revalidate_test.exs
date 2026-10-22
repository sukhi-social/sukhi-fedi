# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiApi.RevalidateTest do
  use ExUnit.Case, async: true

  alias SukhiApi.Revalidate

  test "a first request gets the body, a validator and a short max-age" do
    {:ok, resp} = Revalidate.json(%{headers: []}, ~s([{"shortcode":"a"}]))
    assert resp.status == 200
    assert {"content-type", "application/json"} in resp.headers
    assert {"etag", _} = List.keyfind(resp.headers, "etag", 0)
    assert {"cache-control", "public, max-age=60" <> _} = List.keyfind(resp.headers, "cache-control", 0)
  end

  test "a matching If-None-Match (even weak, even in a list) gets a bodiless 304" do
    body = ~s([{"shortcode":"a"}])
    {:ok, %{headers: headers}} = Revalidate.json(%{headers: []}, body)
    {"etag", etag} = List.keyfind(headers, "etag", 0)

    for sent <- [etag, "W/" <> etag, ~s("other", ) <> etag] do
      {:ok, resp} = Revalidate.json(%{headers: [{"If-None-Match", sent}]}, body)
      assert resp.status == 304
      assert resp.body == ""
    end
  end

  test "a changed body is a changed tag, so it is sent in full" do
    {:ok, %{headers: headers}} = Revalidate.json(%{headers: []}, "[1]")
    {"etag", etag} = List.keyfind(headers, "etag", 0)

    {:ok, resp} = Revalidate.json(%{headers: [{"if-none-match", etag}]}, "[2]")
    assert resp.status == 200
    assert resp.body == "[2]"
  end
end
