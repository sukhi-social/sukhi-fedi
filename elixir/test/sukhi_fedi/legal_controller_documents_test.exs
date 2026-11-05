# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Web.LegalControllerDocumentsTest do
  # Swaps the kept documents, so it cannot overlap the async tests.
  use ExUnit.Case, async: false

  @moduletag :integration

  import Plug.Test

  alias SukhiFedi.Legal.Documents
  alias SukhiFedi.Web.LegalController

  setup do
    dir = Path.join(System.tmp_dir!(), "legal_ctl_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    on_exit(fn ->
      File.rm_rf(dir)
      Documents.install!(%{})
    end)

    %{dir: dir}
  end

  defp install(dir, files) do
    for {name, body} <- files, do: File.write!(Path.join(dir, name), body)
    Documents.install!(%{"legal" => %{"dir" => dir}})
  end

  defp page(doc, query \\ "") do
    conn = conn(:get, "/#{doc}#{query}") |> Plug.Conn.fetch_query_params()
    conn = apply(LegalController, doc, [conn])
    assert conn.status == 200
    conn.resp_body
  end

  test "the instance's own documents replace the bundled ones", %{dir: dir} do
    install(dir, [
      {"terms.en.md", "# Example Social terms\n\nGoverned by the laws of Example."},
      {"privacy.en.md", "# Example Social privacy\n\nWrite to ops@example.org."}
    ])

    terms = page(:terms)
    assert terms =~ "Example Social terms"
    assert terms =~ ~s(<html lang="en">)
    refute terms =~ "f3liz-dev@proton.me"
    refute terms =~ "ようこそ"

    privacy = page(:privacy)
    assert privacy =~ "ops@example.org"
    refute privacy =~ "f3liz-dev@proton.me"
    refute privacy =~ "個人情報保護法"
  end

  test "English-only: no language toggle to a page that does not exist, and the pages link each other",
       %{dir: dir} do
    install(dir, [{"terms.en.md", "# T"}, {"privacy.en.md", "# P"}])

    privacy = page(:privacy)
    refute privacy =~ "日本語"
    refute privacy =~ "한국어"
    assert privacy =~ ~s(<a href="/terms">Terms of Service</a>)
    # an unknown language is the default, not an error
    assert page(:privacy, "?lang=ko") =~ ~r{<h1>\s*P\s*</h1>}
  end

  test "several languages: ja is the default, the others are one click away", %{dir: dir} do
    install(dir, [
      {"terms.ja.md", "# 規約"},
      {"terms.en.md", "# Terms EN"},
      {"privacy.ja.md", "# 方針"},
      {"privacy.en.md", "# Privacy EN"}
    ])

    assert page(:terms) =~ "規約"
    assert page(:terms, "?lang=en") =~ "Terms EN"

    en = page(:privacy, "?lang=en")
    assert en =~ ~s(href="/privacy">日本語</a>)
    assert en =~ ~s(<a href="/terms?lang=en">Terms of Service</a>)

    ja = page(:privacy)
    assert ja =~ ~s(href="/privacy?lang=en">English</a>)
    assert ja =~ ~s(<a href="/terms">利用規約</a>)
  end

  test "the sign-up return button still rides along", %{dir: dir} do
    install(dir, [{"terms.en.md", "# T"}, {"privacy.en.md", "# P"}])
    assert page(:terms, "?signup=true") =~ ~s(href="/signup")
  end
end
