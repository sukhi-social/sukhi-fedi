# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule CoreViews.IdsTest do
  use CoreViews.Case
  alias CoreViews.{Ids, Records}

  @uuid "01a21aec-c46b-7226-b63c-5ab791b7584a"
  @s1 "s1kon20261127t09z13b24vcf2tpy8vep2a"

  test "s1 is the draft's example, and goes back to the UUID" do
    assert Ids.s1(@uuid, "on") == @s1

    assert {:ok, %{uuid: @uuid, code: "on", unix_ms: ms}} = Ids.decode_s1(@s1)
    assert ms |> DateTime.from_unix!(:millisecond) |> DateTime.to_date() == ~D[2026-11-27]

    for _ <- 1..200 do
      uuid = Ecto.UUID.generate(version: 7)
      assert {:ok, %{uuid: ^uuid}} = uuid |> Ids.s1("xa") |> Ids.decode_s1()
    end

    assert Ids.decode_s1(String.replace(@s1, "20261127", "20261327")) == :error
    assert Ids.decode_s1(binary_part(@s1, 0, 20) <> "zzzzzzzzzzzzzzz") == :error
  end

  test "forms for people are normalized" do
    assert Ids.normalize("S1KON-20261127-09Z13B-24VCF-2TPY8-VEP2A") == @s1
    assert Ids.normalize("s1kon2O261127T09zl3b24vcf2tpy8vep2a") == @s1
  end

  test "s0kza is made from the URI alone" do
    id = Ids.s0kza("https://far.test/notes/1")
    assert byte_size(id) == 31
    assert id == Ids.s0kza("https://far.test/notes/1")
    refute id == Ids.s0kza("https://far.test/notes/1/")
  end

  test "every record has a UUIDv7; local ones s1k" do
    note = note!(2)
    boost = boost!(3, note)
    {:ok, reaction} = react(3, note, "a")
    follow = follow!(3, 2)

    for {record, code} <- [{note, "on"}, {boost, "xa"}, {reaction, "xl"}, {follow, "xf"}] do
      assert <<_::binary-14, "7", _::binary>> = record.uuid
      assert record.api_id == Ids.s1(record.uuid, code)
      assert record.short_id == binary_part(record.api_id, 0, 24)
      assert Records.resolve(record.api_id).uuid == record.uuid
      assert Repo.get_by(record.__struct__, uuid: record.uuid).id == record.id
    end
  end

  test "remote records have s0kza, and a UUIDv7 of ours" do
    uri = "https://far.test/notes/1"
    note = note!(2, domain: "far.test", ap_id: uri)
    boost = boost!(3, note, remote: true, ap_id: "https://far.test/boosts/1")

    for {record, from} <- [{note, uri}, {boost, "https://far.test/boosts/1"}] do
      assert <<_::binary-14, "7", _::binary>> = record.uuid
      assert record.api_id == Ids.s0kza(from)
      assert record.short_id == nil
      assert Records.resolve(String.upcase(record.api_id)).id == record.id
    end

    attrs = %{account_id: 2, content: "x", domain: "far.test"}
    assert {:error, changeset} = insert(%Note{}, &Note.changeset/2, attrs)
    assert changeset.errors[:ap_id]
  end

  test "a short ID, or a longer start, finds the record; a wrong one does not" do
    note = note!(2)

    assert Records.resolve(note.short_id).id == note.id
    assert Records.resolve(binary_part(note.api_id, 0, 30)).id == note.id
    assert Records.resolve(binary_part(note.api_id, 0, 23)) == nil
    assert Records.resolve(note.short_id <> "zzzzzz") == nil
    assert Records.resolve("s1") == nil
    assert Records.resolve("123") == nil
  end

  test "a deleted note keeps its IDs and answers as a tombstone" do
    note = note!(2)
    {:ok, _} = Repo.delete(note)
    uuid = note.uuid

    assert %Tombstone{uuid: ^uuid} = Records.resolve(note.api_id)
    assert %Tombstone{} = Records.resolve(note.short_id)
  end

  test "a taken short ID gets a new UUIDv7" do
    first = note!(2, uuid: @uuid)
    # the same millisecond and the same first random bits
    near = String.replace_suffix(@uuid, "4a", "4b")
    second = note!(2, uuid: near)

    assert first.uuid == @uuid
    assert second.uuid != near
    assert second.short_id != first.short_id
  end

  test "a UUID that is not version 7 is refused" do
    attrs = %{account_id: 2, content: "x", uuid: Ecto.UUID.generate()}
    assert {:error, changeset} = insert(%Note{}, &Note.changeset/2, attrs)
    assert changeset.errors[:uuid]
  end

  test "a remote URI is one record" do
    uri = "https://far.test/notes/1"
    note!(2, domain: "far.test", ap_id: uri)

    attrs = %{account_id: 2, content: "again", domain: "far.test", ap_id: uri}
    assert {:error, changeset} = insert(%Note{}, &Note.changeset/2, attrs)
    assert Keyword.keys(changeset.errors) -- [:ap_id, :api_id] == []
  end
end
