# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Schema.JoinApplication do
  @moduledoc """
  One application to join (docs/JOIN.md).

  The changesets are the only place the shape is enforced. Every question
  is optional ("write only what you want to") except the address; text is
  trimmed and an empty answer is stored as nothing. The three keys
  (`receipt`, `claim_hash`, `edit_hash`) are never cast from a request —
  the context sets them.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias SukhiFedi.Auth.EmailAuth

  @name_max 40
  @found_max 1000
  @hope_max 2000
  @langs ~w(ja ko en)

  schema "join_applications" do
    field(:receipt, :string)
    field(:email, :string)
    field(:call_name, :string)
    field(:found, :string)
    field(:hope, :string)
    field(:lang, :string)
    field(:check_on, :date)
    field(:claim_hash, :string)
    field(:edit_hash, :string)
    field(:confirmed_at, :utc_datetime)

    timestamps(type: :utc_datetime, inserted_at: :created_at)
  end

  @type t :: %__MODULE__{}

  @doc "A new application. `keys` carries what the context minted."
  @spec create_changeset(map(), map()) :: Ecto.Changeset.t()
  def create_changeset(attrs, %{receipt: _, claim_hash: _, check_on: _} = keys) do
    %__MODULE__{receipt: keys.receipt, claim_hash: keys.claim_hash, check_on: keys.check_on}
    |> cast(attrs, [:email, :call_name, :found, :hope, :lang])
    |> answers()
    |> email()
    |> update_change(:lang, &lang/1)
  end

  @doc "Words changed through the edit link. The address does not move here."
  @spec edit_changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def edit_changeset(%__MODULE__{} = app, attrs) do
    app |> cast(attrs, [:call_name, :found, :hope]) |> answers()
  end

  @doc "A corrected address, before anyone has confirmed receiving the mail."
  @spec email_changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def email_changeset(%__MODULE__{} = app, attrs) do
    app |> cast(attrs, [:email]) |> email()
  end

  @doc "\"Yes, I got it\": the edit key's hash is stored with the time."
  @spec confirm_changeset(%__MODULE__{}, String.t()) :: Ecto.Changeset.t()
  def confirm_changeset(%__MODULE__{} = app, edit_hash) when is_binary(edit_hash) do
    change(app,
      edit_hash: edit_hash,
      confirmed_at: DateTime.utc_now() |> DateTime.truncate(:second)
    )
  end

  @doc "Undo `confirm_changeset/2` when the mail that carried the link did not go."
  @spec unconfirm_changeset(%__MODULE__{}) :: Ecto.Changeset.t()
  def unconfirm_changeset(%__MODULE__{} = app), do: change(app, edit_hash: nil, confirmed_at: nil)

  defp answers(cs) do
    cs
    |> update_change(:call_name, &blank_to_nil/1)
    |> update_change(:found, &blank_to_nil/1)
    |> update_change(:hope, &blank_to_nil/1)
    |> validate_length(:call_name, max: @name_max)
    |> validate_length(:found, max: @found_max)
    |> validate_length(:hope, max: @hope_max)
  end

  defp email(cs) do
    cs
    |> validate_required([:email])
    |> validate_change(:email, fn :email, value ->
      case EmailAuth.normalize_email(value) do
        {:ok, _} -> []
        {:error, :invalid_email} -> [email: "is invalid"]
      end
    end)
    |> update_change(:email, fn value ->
      case EmailAuth.normalize_email(value) do
        {:ok, norm} -> norm
        {:error, :invalid_email} -> value
      end
    end)
  end

  defp lang(l) when l in @langs, do: l
  defp lang(_), do: nil

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(value), do: value
end
