# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Schema.Deco do
  use Ecto.Schema
  import Ecto.Changeset

  # 板一枚（natadeco の「デコ」）。`slug` が URL に出る名前で、
  # `name` が人の読む名前。まだ連合しない ── AP の Group actor を
  # 生やすのは、板の中身が固まってからでいい。
  schema "decos" do
    field(:slug, :string)
    field(:name, :string)
    field(:description, :string)
    field(:created_by_id, :integer)

    timestamps(type: :utc_datetime, inserted_at: :created_at, updated_at: false)
  end

  @slug_format ~r/\A[a-z0-9][a-z0-9_-]{0,29}\z/

  # 板はどれも `/d/:slug` の下に居るので、`posts` や `new` のような
  # 名前ももう他の一段路とぶつからない(以前は `/:slug` が直下にあって
  # 予約が要った)。`api`・`admin` だけは、衝突ではなく紛らわしさ
  # そのものを避けたくて残す。
  @reserved ~w(api admin)

  def changeset(deco, attrs) do
    deco
    |> cast(attrs, [:slug, :name, :description, :created_by_id])
    |> update_change(:slug, &String.downcase(String.trim(&1 || "")))
    |> validate_required([:slug, :name])
    |> validate_format(:slug, @slug_format)
    |> validate_exclusion(:slug, @reserved)
    |> validate_length(:name, max: 60)
    |> validate_length(:description, max: 2_000)
    |> unique_constraint(:slug)
  end
end
