# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Repo.Migrations.AddTranslationToAccounts do
  use Ecto.Migration

  @moduledoc """
  A person's own settings for translating posts (SukhiFedi.Translate).

  `translate_reads` — languages they read, as a comma list ("ja,en"); a post in
  one of these never offers a "translate" button. `translate_learns` — languages
  they are studying; posts in these are shown with the translation closed and
  quiet. `translate_engine` — "libre" (this server's translator) or "deepl"
  (their own key); NULL means libre.

  `translate_deepl_key` is the person's DeepL API key, sealed (AES-GCM, bound to
  the account id — `SukhiFedi.Translate.Key`); it is write-only and never leaves
  the gateway. `translate_deepl_key_hint` is its last four characters, the only
  part a settings page may show.
  """

  def change do
    alter table(:accounts) do
      add(:translate_reads, :text)
      add(:translate_learns, :text)
      add(:translate_engine, :string)
      add(:translate_deepl_key, :binary)
      add(:translate_deepl_key_hint, :string)
    end
  end
end
