# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Schema.AccountNote do
  use Ecto.Schema
  use Ecto.Hosi.Schema
  import Ecto.Changeset

  # A private label the author keeps about a target account: plain text,
  # local-only, never federated, shown only to the author alongside the
  # target's real name (never replacing it). One note per (author, target).
  # the catalog's unique indexes, kept by the store
  hosi_unique([:author_account_id, :target_account_id],
    name: "account_notes_author_account_id_target_account_id_index"
  )

  # the catalog's foreign keys (ON DELETE) and write rules, kept by the adapter
  hosi_ref(:author_account_id, to: "accounts", on_delete: :cascade, name: "account_notes_author_account_id_fkey")
  hosi_ref(:target_account_id, to: "accounts", on_delete: :cascade, name: "account_notes_target_account_id_fkey")

  schema "account_notes" do
    field(:author_account_id, :integer)
    field(:target_account_id, :integer)
    field(:comment, :string, default: "")
    timestamps()
  end

  @max_len 2_000

  @doc """
  Changeset for setting a private note. Plain text — never rendered as
  HTML — so no scrubber; only a length cap so the column can't be abused.
  """
  def changeset(note, attrs) do
    note
    |> cast(attrs, [:author_account_id, :target_account_id, :comment])
    |> validate_required([:author_account_id, :target_account_id])
    |> validate_length(:comment, max: @max_len)
  end
end
