# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Legal.DocumentsTest do
  # install!/1 keeps its set in :persistent_term, which the controller reads.
  use ExUnit.Case, async: false

  alias SukhiFedi.Legal.Documents

  setup do
    dir = Path.join(System.tmp_dir!(), "legal_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    on_exit(fn ->
      File.rm_rf(dir)
      Documents.install!(%{})
    end)

    %{dir: dir}
  end

  defp put(dir, name, body), do: File.write!(Path.join(dir, name), body)

  defp complete(dir) do
    put(dir, "terms.en.md", "# Our terms\n\nWrite to **ops@example.org**.")
    put(dir, "privacy.en.md", "# Our privacy policy")
  end

  test "renders each file once into {document, language}", %{dir: dir} do
    complete(dir)
    put(dir, "terms.ja.md", "# 規約")
    put(dir, "privacy.ja.md", "# 方針​です")

    set = Documents.load!(dir)

    assert Map.keys(set.terms) |> Enum.sort() == ["en", "ja"]
    assert set.terms["en"] =~ "<strong>ops@example.org</strong>"
    assert set.privacy["ja"] =~ "方針<wbr>です"
  end

  test "install! keeps the set, and forgets it when the config names no directory", %{dir: dir} do
    complete(dir)
    config = %{"legal" => %{"dir" => dir}}

    assert Documents.install!(config) == {:custom, dir}
    assert Documents.all().terms["en"] =~ "Our terms"

    assert Documents.install!(%{}) == :bundled
    assert Documents.all() == nil
  end

  test "install! refuses to start when the config names neither a directory nor a flavor" do
    previous = Application.get_env(:sukhi_fedi, :legal_flavor)
    Application.put_env(:sukhi_fedi, :legal_flavor, nil)
    on_exit(fn -> Application.put_env(:sukhi_fedi, :legal_flavor, previous) end)

    assert_raise ArgumentError, ~r/names no legal documents/, fn ->
      Documents.install!(%{})
    end
  end

  test "refuses to start on anything it cannot serve faithfully", %{dir: dir} do
    assert_raise ArgumentError, ~r/no terms\.<lang>\.md/, fn -> Documents.load!(dir) end

    assert_raise ArgumentError, ~r/cannot read it/, fn ->
      Documents.load!(Path.join(dir, "missing"))
    end

    put(dir, "terms.en.md", "x")
    assert_raise ArgumentError, ~r/no privacy\.<lang>\.md/, fn -> Documents.load!(dir) end

    put(dir, "privacy.ja.md", "x")
    assert_raise ArgumentError, ~r/same languages/, fn -> Documents.load!(dir) end

    put(dir, "privacy.ja.md", "  \n")
    put(dir, "privacy.en.md", "x")
    assert_raise ArgumentError, ~r/privacy\.ja\.md is empty/, fn -> Documents.load!(dir) end

    File.rm!(Path.join(dir, "privacy.ja.md"))
    put(dir, "terms.fr.md", "x")
    assert_raise ArgumentError, ~r/unsupported language fr/, fn -> Documents.load!(dir) end

    File.rm!(Path.join(dir, "terms.fr.md"))
    put(dir, "terms.en.md", <<0xFF, 0xFE>>)
    assert_raise ArgumentError, ~r/not UTF-8/, fn -> Documents.load!(dir) end
  end

  test "files that are not terms/privacy documents are ignored", %{dir: dir} do
    complete(dir)
    put(dir, "README.md", "notes")
    put(dir, "terms.en.md.bak", "old")

    assert Documents.load!(dir).terms |> Map.keys() == ["en"]
  end
end
