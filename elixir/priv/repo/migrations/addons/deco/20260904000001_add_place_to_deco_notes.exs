defmodule SukhiFedi.Repo.Migrations.AddPlaceToDecoNotes do
  use Ecto.Migration

  def change do
    # どこのことを書いたか。旅の記録(travel)が、場所のある一枚だけ
    # 地図にも置くための一列。`{name, url, lat, lng}` を一つの map で
    # 持つ ── 無い記録のほうが多いので、列を四つ並べない。
    #
    # notes には置かない: 座標を使うのはいまのところこの板だけで、
    # 連合に出す形(AS2 の `location`)はまだ決めていない。
    alter table(:deco_notes) do
      add(:place, :map)
    end
  end
end
