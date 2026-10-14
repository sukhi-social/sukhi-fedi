# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.BackendTest do
  # Flips application env, so not async.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias SukhiFedi.Backend

  defmodule Doubler do
    def sanitize(html), do: html <> html
  end

  defmodule Same do
    def sanitize(html), do: html
  end

  defmodule Raiser do
    def sanitize(_html), do: raise("boom")
  end

  setup do
    prev = for k <- [:backends, :shadow_backends], into: %{}, do: {k, Application.get_env(:sukhi_fedi, k)}

    on_exit(fn ->
      for {k, v} <- prev do
        if v == nil, do: Application.delete_env(:sukhi_fedi, k), else: Application.put_env(:sukhi_fedi, k, v)
      end
    end)

    Application.delete_env(:sukhi_fedi, :backends)
    Application.delete_env(:sukhi_fedi, :shadow_backends)
    :ok
  end

  test "with nothing configured each seam answers with its Elixir implementation" do
    assert Backend.impl(:html_sanitizer) == SukhiFedi.HTML.Sanitizer.Elixir
    assert Backend.impl(:linkify_scanner) == SukhiFedi.Linkify.Scanner.Elixir
    assert Backend.impl(:preview_meta) == SukhiFedi.PreviewCards.Meta.Elixir
    assert Backend.impl(:markdown) == SukhiFedi.Markdown.Renderer.Elixir
    assert Backend.implementations(:html_sanitizer) == [SukhiFedi.HTML.Sanitizer.Elixir]
  end

  test "config picks the implementation, per seam" do
    Application.put_env(:sukhi_fedi, :backends, html_sanitizer: Doubler)
    assert Backend.call(:html_sanitizer, :sanitize, ["ab"]) == "abab"
    # another seam is untouched
    assert Backend.impl(:preview_meta) == SukhiFedi.PreviewCards.Meta.Elixir
  end

  test "the facade goes through the backend: HTML.sanitize/1 follows the config" do
    Application.put_env(:sukhi_fedi, :backends, html_sanitizer: Doubler)
    assert SukhiFedi.HTML.sanitize("x") == "xx"
    # non-binaries never reach a backend
    assert SukhiFedi.HTML.sanitize(nil) == nil
  end

  describe "shadow" do
    test "an agreeing shadow is silent and the answer is unchanged" do
      Application.put_env(:sukhi_fedi, :shadow_backends, html_sanitizer: Same)
      log = capture_log(fn -> assert SukhiFedi.HTML.sanitize("plain") == "plain" end)
      assert log == ""
    end

    test "a disagreeing shadow is logged, but the primary's answer stands" do
      Application.put_env(:sukhi_fedi, :shadow_backends, html_sanitizer: Doubler)

      log =
        capture_log(fn ->
          assert SukhiFedi.HTML.sanitize("secret-post-text") == "secret-post-text"
        end)

      assert log =~ "backend shadow disagreement on html_sanitizer.sanitize"
      assert log =~ "SukhiFedi.BackendTest.Doubler"
      # sizes and a hash, never the content
      assert log =~ "primary 16B"
      refute log =~ "secret-post-text"
    end

    test "a shadow that raises is swallowed" do
      Application.put_env(:sukhi_fedi, :shadow_backends, html_sanitizer: Raiser)
      assert SukhiFedi.HTML.sanitize("ok") == "ok"
    end

    test "no shadow configured: it is never asked" do
      Application.put_env(:sukhi_fedi, :backends, html_sanitizer: Same)
      assert Backend.call(:html_sanitizer, :sanitize, ["z"]) == "z"
    end
  end
end
