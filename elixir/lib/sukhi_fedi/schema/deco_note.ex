# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Schema.DecoNote do
  use Ecto.Schema
  import Ecto.Changeset

  # 「この note は、この板のもの」という一行。本文も、書いた人も、
  # notes 側にある。
  schema "deco_notes" do
    field(:deco_id, :integer)
    field(:note_id, :integer)

    # 題・本文の、もう一つの言語ぶん(生の Markdown、HTML 化は読むとき)。
    # notes 側は連合するので単一言語のまま ── ここは natadeco の読み側
    # だけで使う上乗せ。
    field(:title_i18n, :map)
    field(:content_i18n, :map)

    timestamps(type: :utc_datetime, inserted_at: :created_at, updated_at: false)
  end

  # title/content に添えられる、もう一つの言語。どちらが notes 側の
  # 主言語になるかは書いた人が実際に選んだ言語で決まるので、両方
  # 受け付ける(deco.ex と同じ理由 ── ja を既定の主言語に決め打ちしない)。
  @i18n_overlay_langs ~w(ja ko)

  def changeset(deco_note, attrs) do
    deco_note
    |> cast(attrs, [:deco_id, :note_id, :title_i18n, :content_i18n])
    |> validate_required([:deco_id, :note_id])
    |> unique_constraint(:note_id)
    |> validate_i18n_map(:title_i18n, 120)
    |> validate_i18n_map(:content_i18n, 10_000)
  end

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
