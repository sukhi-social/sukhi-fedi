# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Repo.Migrations.CreateMapPeers do
  use Ecto.Migration

  # 路線図ページの「連合の宇宙図」に名前を載せてよいインスタンスの
  # allow-list。bubble_instances と同じ形(domain + 誰が足したか)だが、
  # 役割は別 — bubble はご近所タイムラインの中身、こちらは公開地図の
  # 見せてよい星。admin UI(/admin/map_peers)で管理する。
  def change do
    create table(:map_peers) do
      add :domain, :string, null: false
      add :created_by_id, references(:accounts, on_delete: :nilify_all)
      timestamps()
    end

    create unique_index(:map_peers, [:domain])
  end
end
