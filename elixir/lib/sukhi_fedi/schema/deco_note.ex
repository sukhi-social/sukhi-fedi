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

    # 連合に出すかどうか。notes.visibility は "public" のまま
    # ── これは deco 独自の、配達側だけが見る上乗せ。
    field(:local_only, :boolean, default: false)

    # 長い文章として出すか（AP の `Article`）。既定は `Note` ──
    # Mastodon は Article の本文を出さないので、選んだ人だけのもの。
    field(:as_article, :boolean, default: false)

    # どこのことか。`%{"name" => _, "url" => _, "lat" => _, "lng" => _}`。
    # 場所のある記録だけが持つ ── 旅の板が地図に置くための一枚。
    field(:place, :map)

    timestamps(type: :utc_datetime, inserted_at: :created_at, updated_at: false)
  end

  # title/content に添えられる、もう一つの言語。どちらが notes 側の
  # 主言語になるかは書いた人が実際に選んだ言語で決まるので、両方
  # 受け付ける(deco.ex と同じ理由 ── ja を既定の主言語に決め打ちしない)。
  @i18n_overlay_langs ~w(ja ko)

  def changeset(deco_note, attrs) do
    deco_note
    |> cast(attrs, [:deco_id, :note_id, :title_i18n, :content_i18n, :local_only, :as_article, :place])
    |> validate_required([:deco_id, :note_id])
    |> unique_constraint(:note_id)
    |> validate_i18n_map(:title_i18n, 120)
    |> validate_i18n_map(:content_i18n, 10_000)
    |> validate_place()
  end

  # 場所は、座標が地球の上にあって、名前と URL が短ければいい。
  # 空の map や nil は「場所なし」として nil に揃える。
  defp validate_place(changeset) do
    case get_change(changeset, :place) do
      nil ->
        changeset

      place when place == %{} ->
        put_change(changeset, :place, nil)

      %{} = place ->
        lat = number(place["lat"] || place[:lat])
        lng = number(place["lng"] || place[:lng])
        name = to_string(place["name"] || place[:name] || "")
        url = to_string(place["url"] || place[:url] || "")

        cond do
          is_nil(lat) or is_nil(lng) or lat < -90 or lat > 90 or lng < -180 or lng > 180 ->
            add_error(changeset, :place, "の座標が地図の上にありません")

          String.length(name) > 120 ->
            add_error(changeset, :place, "の名前は120文字までです")

          String.length(url) > 500 ->
            add_error(changeset, :place, "のリンクが長すぎます")

          true ->
            put_change(changeset, :place, %{"name" => name, "url" => url, "lat" => lat, "lng" => lng})
        end

      _ ->
        add_error(changeset, :place, "の形が読めません")
    end
  end

  defp number(n) when is_number(n), do: n / 1

  defp number(s) when is_binary(s) do
    case Float.parse(s) do
      {f, ""} -> f
      _ -> nil
    end
  end

  defp number(_), do: nil

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
