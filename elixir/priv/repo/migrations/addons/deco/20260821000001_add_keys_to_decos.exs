defmodule SukhiFedi.Repo.Migrations.AddKeysToDecos do
  use Ecto.Migration

  def change do
    # デコの Group actor 用の鍵。個人アカウント(accounts)と同じ形
    # (RSA + Ed25519)を持たせる ── 別のキー生成経路を作らないため。
    alter table(:decos) do
      add(:public_key_pem, :text)
      add(:public_key_jwk, :map)
      add(:private_key_jwk, :map)
      add(:ed25519_private_key_jwk, :map)
      add(:ed25519_public_multibase, :string)
    end
  end
end
