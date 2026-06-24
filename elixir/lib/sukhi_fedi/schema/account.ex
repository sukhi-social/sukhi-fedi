# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Schema.Account do
  use Ecto.Schema
  import Ecto.Changeset

  schema "accounts" do
    field :username, :string
    field :display_name, :string
    field :summary, :string
    field :emojis, {:array, :map}, default: []
    # Profile fields: a person's own static key/value rows (Mastodon
    # `fields` / AP `attachment` PropertyValue). They federate, so a
    # remote viewer sees exactly what the person wrote. Each row is
    # `%{"name" => String.t(), "value" => String.t()}`; for remote rows
    # this mirrors the upstream actor's `attachment`.
    field :fields, {:array, :map}, default: []
    field :private_key_jwk, :map
    field :public_key_jwk, :map
    # PEM-encoded SubjectPublicKeyInfo — read by actor_controller.ex for
    # ActivityPub actor JSON publication.
    field :public_key_pem, :string
    # Ed25519 pair for FEP-8b32 Object Integrity Proofs. The public key
    # is stored in its Multikey `publicKeyMultibase` form so both
    # ActorJson modules publish `assertionMethod` by reading it — same
    # precomputed pattern as `public_key_pem`.
    field :ed25519_private_key_jwk, :map
    field :ed25519_public_multibase, :string
    # Auto-created actors for the NodeInfo monitor bot.
    field :is_bot, :boolean, default: false
    field :monitored_domain, :string
    field :avatar_url, :string
    field :banner_url, :string
    field :is_admin, :boolean, default: false
    # Manual follow approval (Mastodon `locked` / AP
    # `manuallyApprovesFollowers`). For remote rows this mirrors the
    # value from the upstream actor JSON.
    field :locked, :boolean, default: false
    # Search-indexing consent (FEP-5feb), federated as Mastodon's
    # `toot:discoverable` / `toot:indexable`. Both default to false —
    # consent is given, not assumed. `discoverable` gates discovery
    # surfaces (directories, suggestions); `indexable` gates full-text
    # search/indexing of this actor's posts.
    field :discoverable, :boolean, default: false
    field :indexable, :boolean, default: false
    field :suspended_at, :utc_datetime
    field :suspended_by_id, :id
    field :suspension_reason, :string

    # Account migration (Mastodon Move + AP `alsoKnownAs` / `movedTo`).
    # `aliases` is the set of other identities this person declares as
    # "also me" (the inbound Move handler reads a *new* actor's aliases to
    # confirm bidirectional consent). `moved_to_uri` is set on the *old*
    # identity once it has moved away, so every screen shows the truthful
    # "moved to @new" state. For remote rows both mirror the upstream actor.
    field :aliases, {:array, :string}, default: []
    field :moved_to_uri, :string

    # Remote-actor mirror columns. `domain IS NULL` ⇔ local account.
    # For remote rows `actor_uri` is the canonical AP id and `inbox_url`
    # / `shared_inbox_url` come from the actor JSON.
    field :domain, :string
    field :actor_uri, :string
    field :inbox_url, :string
    field :shared_inbox_url, :string
    field :public_key_id, :string
    field :last_fetched_at, :utc_datetime

    # Local-account credentials. All `domain IS NULL` only. `email` is
    # required at signup since 2026-06; rows from before may still lack
    # it (the SPA nudges them). `email_verified_at` marks an address
    # that completed the code round-trip — email login keys off it.
    field :email, :string
    field :email_verified_at, :utc_datetime
    field :password_hash, :string
    # Authenticator-app 2FA. `totp_secret` is set at setup time but the
    # factor counts only once `totp_enabled_at` is non-NULL (the user
    # proved they scanned it). `totp_last_used_step` rejects replay of
    # the current 30-second code.
    field :totp_secret, :binary
    field :totp_enabled_at, :utc_datetime
    field :totp_last_used_step, :integer

    timestamps(type: :utc_datetime, inserted_at: :created_at, updated_at: false)
  end

  @doc """
  Changeset used by `RemoteAccounts.upsert_from_actor_json/1` to mirror
  a remote actor into the local directory. `domain` must be set
  (NOT NULL ⇔ remote). Idempotent on `actor_uri`.
  """
  def changeset_remote(account, attrs) do
    account
    |> cast(attrs, [
      :username,
      :domain,
      :display_name,
      :summary,
      :emojis,
      :fields,
      :actor_uri,
      :inbox_url,
      :shared_inbox_url,
      :public_key_id,
      :public_key_pem,
      :avatar_url,
      :banner_url,
      :locked,
      :aliases,
      :moved_to_uri,
      :last_fetched_at
    ])
    |> update_change(:summary, &SukhiFedi.HTML.sanitize/1)
    |> update_change(:fields, &cast_fields/1)
    |> validate_required([:username, :domain, :actor_uri])
  end

  @doc """
  Changeset for `PATCH /api/v1/accounts/update_credentials`.

  Mastodon allows clients to update display_name, note (we map to
  `summary`), avatar/header URLs, `bot` flag, and `locked` (manual
  follow approval). We don't expose username changes — the AP id is
  immutable.
  """
  def changeset_credentials(account, attrs) do
    attrs = normalize_credentials_attrs(attrs)

    account
    |> cast(attrs, [
      :display_name,
      :summary,
      :fields,
      :avatar_url,
      :banner_url,
      :is_bot,
      :locked,
      :discoverable,
      :indexable
    ])
    |> update_change(:summary, &SukhiFedi.HTML.sanitize/1)
    |> update_change(:fields, &cast_fields/1)
    |> validate_length(:display_name, max: 100)
    |> validate_length(:summary, max: 1024)
  end

  @doc """
  Changeset for `POST /api/v1/accounts` — local signup. `domain` is
  forced to `nil`; the AP keypair and `public_key_pem` are minted by
  the caller before insert (see `SukhiFedi.LocalAccounts.create/1`).

  `password_hash` is the already-hashed value; raw passwords never
  reach this layer.
  """
  def changeset_local(account, attrs) do
    account
    |> cast(attrs, [
      :username,
      :display_name,
      :email,
      :password_hash,
      :public_key_pem,
      :public_key_jwk,
      :private_key_jwk,
      :ed25519_private_key_jwk,
      :ed25519_public_multibase
    ])
    |> put_change(:domain, nil)
    # password_hash is NOT required — passwordless accounts are the
    # norm since 2026-06; the verified-at-birth email is the door.
    # `LocalAccounts` enforces the 8-byte floor when one IS set.
    |> validate_required([:username, :public_key_pem])
    |> validate_format(:username, ~r/^[a-z0-9_]{1,30}$/,
      message: "は小文字英数字とアンダースコアのみ、30字までです"
    )
    |> validate_length(:display_name, max: 100)
    |> validate_email()
    |> unique_constraint(:username, name: :accounts_local_username_index)
  end

  @doc """
  Shared email shape + uniqueness rule for local rows. Presence is the
  caller's call (signup requires it, `create_admin` doesn't), but any
  email that does land must look like one and be unclaimed among local
  accounts — `EmailAuth.confirm/2` routes through here too.
  """
  def validate_email(changeset) do
    changeset
    |> validate_format(:email, ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/,
      message: "の形が、メールアドレスに見えません"
    )
    |> validate_length(:email, max: 254)
    |> unique_constraint(:email,
      name: :accounts_local_email_index,
      message: "は、もう使われています"
    )
  end

  # The one gate for profile `fields`, walked by both the local edit and
  # the remote mirror (so a remote actor's `attachment` is held to the
  # same caps as our own users'). Keeps at most 4 rows; each name is
  # plain text (escaped, like local note content) and each value is run
  # through the shared bio scrubber `HTML.sanitize/1` — never an inline
  # second scrubber (CODE_STYLE §0/§3). Blank-named rows are dropped.
  @max_fields 4
  @max_field_name 255
  @max_field_value 512
  defp cast_fields(rows) when is_list(rows) do
    rows
    |> Enum.map(&one_field/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.take(@max_fields)
  end

  defp cast_fields(_), do: []

  defp one_field(row) when is_map(row) do
    name = row |> field_str("name") |> String.slice(0, @max_field_name)
    value = row |> field_str("value") |> SukhiFedi.HTML.sanitize() |> String.slice(0, @max_field_value)

    case String.trim(name) do
      "" -> nil
      _ -> %{"name" => SukhiFedi.HTML.escape(name), "value" => value}
    end
  end

  defp one_field(_), do: nil

  defp field_str(row, key) do
    case Map.get(row, key) || Map.get(row, String.to_existing_atom(key)) do
      v when is_binary(v) -> v
      _ -> ""
    end
  rescue
    ArgumentError -> ""
  end

  defp normalize_credentials_attrs(attrs) when is_map(attrs) do
    attrs
    |> normalize_alias("note", "summary")
    |> normalize_alias("bot", "is_bot")
  end

  defp normalize_alias(attrs, from, to) do
    case Map.get(attrs, from) || Map.get(attrs, String.to_existing_atom(from)) do
      nil -> attrs
      v -> attrs |> Map.put(to, v) |> Map.delete(from) |> Map.delete(String.to_existing_atom(from))
    end
  rescue
    ArgumentError -> attrs
  end
end
