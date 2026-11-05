# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Translate.SettingsTest do
  @moduledoc "The translation settings on `Account.changeset_credentials/2`."
  use ExUnit.Case, async: true

  alias SukhiFedi.Schema.Account
  alias SukhiFedi.Translate.Key

  @key "0c1d2e3f-4a5b-6c7d-8e9f-a0b1c2d3e4f5"

  defp cs(attrs, account \\ %Account{id: 7}), do: Account.changeset_credentials(account, attrs)

  test "languages are two-or-three-letter codes, lower-cased, de-duplicated, in order" do
    c = cs(%{"translate_reads" => "JA, ko-KR en  xx1 en toolong", "translate_learns" => "ko"})
    assert c.valid?
    assert Ecto.Changeset.get_change(c, :translate_reads) == "ja,ko,en"
    assert Ecto.Changeset.get_change(c, :translate_learns) == "ko"
  end

  test "at most eight languages are kept; nothing valid left means none" do
    c = cs(%{"translate_reads" => "aa bb cc dd ee ff gg hh ii jj", "translate_learns" => "1 22 !!"})
    assert Ecto.Changeset.get_change(c, :translate_reads) == "aa,bb,cc,dd,ee,ff,gg,hh"
    assert Ecto.Changeset.get_change(c, :translate_learns) == nil
  end

  test "the engine is libre or deepl; blank means the server's own" do
    refute cs(%{"translate_engine" => "google"}).valid?
    assert cs(%{"translate_engine" => "libre"}).valid?
    c = cs(%{"translate_engine" => ""}, %Account{id: 7, translate_engine: "libre"})
    assert c.valid?
    assert Ecto.Changeset.get_field(c, :translate_engine) == nil
  end

  test "a DeepL key is sealed on the way in, and only its last four characters are kept in the open" do
    c = cs(%{"translate_deepl_key" => @key <> ":fx", "translate_engine" => "deepl"})
    assert c.valid?

    sealed = Ecto.Changeset.get_change(c, :translate_deepl_key)
    assert is_binary(sealed) and sealed != @key <> ":fx"
    assert Ecto.Changeset.get_change(c, :translate_deepl_key_hint) == "e4f5"
    assert {:ok, @key <> ":fx"} == Key.open(sealed, 7)
  end

  test "the plaintext does not survive in `inspect`" do
    c = cs(%{"translate_deepl_key" => @key})
    refute inspect(c) =~ @key
    refute inspect(Ecto.Changeset.apply_changes(c)) =~ @key
  end

  test "something that is not a DeepL key is an error, not a stored value" do
    c = cs(%{"translate_deepl_key" => "hunter2"})
    refute c.valid?
    assert {"is not a DeepL API key", _} = c.errors[:translate_deepl_key]
    assert Ecto.Changeset.get_change(c, :translate_deepl_key) == nil
  end

  test "a value sent as the sealed column itself is never taken as the sealed key" do
    # `translate_deepl_key` is the form field for plaintext; whatever it carries is sealed or refused.
    c = cs(%{"translate_deepl_key" => <<1, 2, 3>>})
    refute c.valid?
  end

  test "an empty key field changes nothing" do
    {:ok, sealed, hint} = Key.seal(@key, 7)
    account = %Account{id: 7, translate_deepl_key: sealed, translate_deepl_key_hint: hint, translate_engine: "deepl"}
    c = cs(%{"translate_deepl_key" => ""}, account)

    assert c.valid?
    assert c.changes == %{}
  end

  test "deepl cannot be chosen without a key" do
    c = cs(%{"translate_engine" => "deepl"})
    refute c.valid?
    assert {"needs a DeepL API key", _} = c.errors[:translate_engine]

    {:ok, sealed, hint} = Key.seal(@key, 7)
    owner = %Account{id: 7, translate_deepl_key: sealed, translate_deepl_key_hint: hint}
    assert cs(%{"translate_engine" => "deepl"}, owner).valid?
  end

  test "removing the key also takes deepl off, and wins over a key sent in the same form" do
    {:ok, sealed, hint} = Key.seal(@key, 7)
    owner = %Account{id: 7, translate_deepl_key: sealed, translate_deepl_key_hint: hint, translate_engine: "deepl"}

    c = cs(%{"translate_deepl_key_clear" => "true", "translate_deepl_key" => @key}, owner)
    assert c.valid?
    assert Ecto.Changeset.get_field(c, :translate_deepl_key) == nil
    assert Ecto.Changeset.get_field(c, :translate_deepl_key_hint) == nil
    assert Ecto.Changeset.get_field(c, :translate_engine) == nil
  end
end
