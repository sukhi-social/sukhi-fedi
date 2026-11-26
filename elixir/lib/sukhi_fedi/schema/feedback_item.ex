# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Schema.FeedbackItem do
  @moduledoc """
  One piece of feedback in the operator's inbox (docs/FEEDBACK.md).

  The changeset is the only place the shape is enforced: the body is
  trimmed and must be 1..2000 characters; `screen`, `lang`, `version`
  have their own small caps. `account_id` is never cast from the request;
  the context sets it from the verified viewer.
  """
  use Ecto.Schema
  use Ecto.Hosi.Schema
  import Ecto.Changeset

  @body_max 2000

  # the catalog's foreign keys (ON DELETE) and write rules, kept by the adapter
  hosi_ref(:account_id, to: "accounts", on_delete: :nilify, name: "feedback_items_account_id_fkey")
  hosi_ref(:handled_by_id, to: "accounts", on_delete: :nilify, name: "feedback_items_handled_by_id_fkey")

  schema "feedback_items" do
    field(:body, :string)
    field(:screen, :string)
    field(:lang, :string)
    field(:version, :string)
    field(:account_id, :integer)
    field(:handled_at, :utc_datetime)
    field(:handled_by_id, :integer)

    timestamps(type: :utc_datetime, inserted_at: :created_at, updated_at: false)
  end

  @spec changeset(map(), integer() | nil) :: Ecto.Changeset.t()
  def changeset(attrs, account_id) when is_nil(account_id) or is_integer(account_id) do
    %__MODULE__{account_id: account_id}
    |> cast(attrs, [:body, :screen, :lang, :version])
    |> update_change(:body, &String.trim/1)
    |> validate_required([:body])
    |> validate_length(:body, min: 1, max: @body_max)
    |> validate_length(:screen, max: 64)
    |> validate_length(:lang, max: 16)
    |> validate_length(:version, max: 64)
  end

  @doc "The handled-mark: who, and when."
  @spec handled_changeset(%__MODULE__{}, integer()) :: Ecto.Changeset.t()
  def handled_changeset(%__MODULE__{} = item, admin_id) when is_integer(admin_id) do
    change(item,
      handled_at: DateTime.utc_now() |> DateTime.truncate(:second),
      handled_by_id: admin_id
    )
  end
end
