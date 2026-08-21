# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Schema.Deco do
  use Ecto.Schema
  import Ecto.Changeset

  # 板一枚（natadeco の「デコ」）。`slug` が URL に出る名前で、
  # `name` が人の読む名前。AP の Group actor は `{slug}-deco@domain` ──
  # 個人アカウントの username はハイフンを使えない(`^[a-z0-9_]+$`)ので、
  # ハイフン入りのこの形は個人アカウントの名前空間と構造的にぶつからない。
  schema "decos" do
    field(:slug, :string)
    field(:name, :string)
    field(:description, :string)
    field(:created_by_id, :integer)

    # Group actor の鍵。個人アカウントと同じ形(RSA + Ed25519)。
    # ユーザー入力からは触れない ── cast はするが、API 層(deco.ex の
    # capability)が受け取る attrs をあらかじめ絞ってあるので、外から
    # 差し込めるのは create_deco/2 が内部で足す分だけ。
    field(:public_key_pem, :string)
    field(:public_key_jwk, :map)
    field(:private_key_jwk, :map)
    field(:ed25519_private_key_jwk, :map)
    field(:ed25519_public_multibase, :string)

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
    |> cast(attrs, [
      :slug,
      :name,
      :description,
      :created_by_id,
      :public_key_pem,
      :public_key_jwk,
      :private_key_jwk,
      :ed25519_private_key_jwk,
      :ed25519_public_multibase
    ])
    |> update_change(:slug, &String.downcase(String.trim(&1 || "")))
    |> validate_required([:slug, :name])
    |> validate_format(:slug, @slug_format)
    |> validate_exclusion(:slug, @reserved)
    |> validate_length(:name, max: 60)
    |> validate_length(:description, max: 2_000)
    |> unique_constraint(:slug)
  end
end
