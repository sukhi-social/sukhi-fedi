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

    # 名前・説明の、もう一つの言語ぶん。`name`/`description` には
    # 「立てた人が実際に書いた言語」がそのまま入る(既定で日本語、では
    # ない) ── こちらは、もう一方の言語があれば添える場所。
    # 例: %{"ko" => "..."} や %{"ja" => "..."}(韓国語で立てて日本語を
    # 添えた場合はこちら)。
    field(:name_i18n, :map)
    field(:description_i18n, :map)

    timestamps(type: :utc_datetime, inserted_at: :created_at, updated_at: false)
  end

  @slug_format ~r/\A[a-z0-9][a-z0-9_-]{0,29}\z/

  # 板はどれも `/d/:slug` の下に居るので、`posts` や `new` のような
  # 名前ももう他の一段路とぶつからない(以前は `/:slug` が直下にあって
  # 予約が要った)。`api`・`admin` だけは、衝突ではなく紛らわしさ
  # そのものを避けたくて残す。
  @reserved ~w(api admin)

  # `name`/`description` に添えられる、もう一つの言語。どちらが主
  # (`name`)になるかは書いた人が実際に選んだ言語で決まるので、両方
  # 受け付ける ── 「ja は常に主言語」という決め打ちはしない
  # (翻訳は原文への奉仕ではなく、読む相手に向けて書かれるもの)。
  @i18n_overlay_langs ~w(ja ko)

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
      :ed25519_public_multibase,
      :name_i18n,
      :description_i18n
    ])
    |> update_change(:slug, &String.downcase(String.trim(&1 || "")))
    |> validate_required([:slug, :name])
    |> validate_format(:slug, @slug_format)
    |> validate_exclusion(:slug, @reserved)
    |> validate_length(:name, max: 60)
    |> validate_length(:description, max: 2_000)
    |> unique_constraint(:slug)
    |> validate_i18n_map(:name_i18n, 60)
    |> validate_i18n_map(:description_i18n, 2_000)
  end

  # 中身が空文字列だけの言語は落とす(「空欄のタブを送った」を
  # 「その言語で書いた」と区別するため)。キーは対応言語だけ、
  # 値の長さは同じ役割の主言語フィールドと揃える。
  defp validate_i18n_map(changeset, field, max_len) do
    case get_change(changeset, field) do
      nil ->
        changeset

      map when is_map(map) ->
        cleaned =
          map
          |> Map.take(@i18n_overlay_langs)
          |> Enum.reject(fn {_k, v} -> is_nil(v) or String.trim(to_string(v)) == "" end)
          |> Map.new()

        if Enum.any?(cleaned, fn {_k, v} -> String.length(to_string(v)) > max_len end) do
          add_error(changeset, field, "は#{max_len}文字までです")
        else
          put_change(changeset, field, cleaned)
        end
    end
  end
end
