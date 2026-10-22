# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.NoteContentTest do
  use ExUnit.Case, async: true

  # Pure changeset test (no DB), but the runner filters to `--only integration`.
  @moduletag :integration

  import Ecto.Changeset, only: [get_change: 2]
  alias SukhiFedi.Schema.Note

  describe "changeset/3 allow_blank_content" do
    test "blank content is invalid by default" do
      refute Note.changeset(%Note{}, %{content: "", account_id: 1}).valid?
    end

    test "blank content is valid and stored as \"\" when allowed" do
      cs = Note.changeset(%Note{}, %{content: "", account_id: 1}, allow_blank_content: true)
      assert cs.valid?
      assert get_change(cs, :content) == ""
    end

    test "allowing blank content still requires an account" do
      refute Note.changeset(%Note{}, %{content: ""}, allow_blank_content: true).valid?
    end
  end

  describe "changeset/2 escapes local plaintext but sanitizes remote HTML" do
    test "local plaintext keeps tag-shaped text (escaped, not dropped)" do
      cs = Note.changeset(%Note{}, %{content: "I love x<y and List<String>", account_id: 1})
      assert get_change(cs, :content) == "I love x&lt;y and List&lt;String&gt;"
    end

    test "remote HTML (ap_id present in attrs) is sanitized" do
      cs =
        Note.changeset(%Note{}, %{
          content: ~s|<p>hi <script>alert(1)</script></p>|,
          account_id: 1,
          ap_id: "https://remote.example/notes/1"
        })

      out = get_change(cs, :content)
      refute out =~ "<script"
      assert out =~ "hi"
    end

    test "remote Update keeps sanitizing even though ap_id is unchanged" do
      # On a remote edit the existing row already carries ap_id, so it is NOT a
      # change — get_field/2 (effective value) is what tells us this is remote.
      remote = %Note{ap_id: "https://remote.example/notes/1", domain: "remote.example"}
      cs = Note.changeset(remote, %{content: ~s|<p>edited <img src=x onerror=evil></p>|})
      refute get_change(cs, :content) =~ "onerror"
    end
  end
end
