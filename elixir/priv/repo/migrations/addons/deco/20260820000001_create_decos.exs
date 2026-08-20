defmodule SukhiFedi.Repo.Migrations.CreateDecos do
  use Ecto.Migration

  def change do
    # 板そのもの。natadeco の「デコ」一枚。
    create_if_not_exists table(:decos) do
      add(:slug, :string, null: false)
      add(:name, :string, null: false)
      add(:description, :text)
      add(:created_by_id, references(:accounts, on_delete: :nilify_all))

      timestamps(type: :utc_datetime, inserted_at: :created_at, updated_at: false)
    end

    create_if_not_exists(unique_index(:decos, [:slug]))

    # 投稿は notes に相乗りする ── 本文・HTML化・タグ・メディア・連合の
    # 道を二本持ちたくないから。この表が持つのは「どの板のものか」だけ。
    # 書いた人は notes.account_id にいる（note.com と同じで、板の上でも
    # そのままその人の名前で出る）。addon を外しても notes は無傷で残る。
    create_if_not_exists table(:deco_notes) do
      add(:deco_id, references(:decos, on_delete: :delete_all), null: false)
      add(:note_id, references(:notes, on_delete: :delete_all), null: false)

      timestamps(type: :utc_datetime, inserted_at: :created_at, updated_at: false)
    end

    create_if_not_exists(unique_index(:deco_notes, [:note_id]))
    create_if_not_exists(index(:deco_notes, [:deco_id, :note_id]))
  end
end
