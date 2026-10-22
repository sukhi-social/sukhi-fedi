# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Schema.Account do
  use Ecto.Schema
  import Ecto.Changeset

  @max_fields 4
  @max_remote_fields 16
  @max_location 128

  schema "accounts" do
    field :username, :string
    field :display_name, :string
    field :summary, :string
    # Local bios only: the Markdown as typed. `summary` is its rendered HTML.
    field :summary_source, :string
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
    # Misskey-family avatar decorations (the ornament drawn over the icon).
    # ActivityPub actors don't carry them, so remote rows get them from the
    # origin's own API (`Federation.MisskeyDecorations`). Each row is
    # `%{"url", "angle", "flip_h", "offset_x", "offset_y"}`.
    field :avatar_decorations, {:array, :map}, default: []
    field :is_admin, :boolean, default: false
    # Misskey-style profile entries (`vcard:Address` / `vcard:bday`): plain
    # text and a calendar date. Local rows are edited by their person; remote
    # rows mirror the origin.
    field :location, :string
    field :birthday, :date
    # Public badges an admin gave this local account. Each row is
    # `%{"name" => String.t(), "color" => String.t()}`; see `changeset_roles/2`.
    field :roles, {:array, :map}, default: []
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

    # こちらから follow した remote の過去投稿 backfill の進行状態。
    # 詳しくは `Federation.OutboxBackfill` と
    # `priv/repo/migrations/core/20260922000001_add_backfill_state_to_accounts.exs`。
    field :backfill_state, :string
    field :backfill_attempted_at, :utc_datetime
    field :backfill_mirrored, :integer, default: 0
    field :backfill_error, :string

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

    # おやすみ. While `now` is before this, no push leaves the building —
    # for every device at once, which is why it sits on the account and
    # not on the per-device subscription. NULL = not quiet. It gates the
    # doorbell only; the notification list is unaffected.
    field :quiet_until, :utc_datetime

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
      :location,
      :birthday,
      :last_fetched_at
    ])
    |> update_change(:location, &cut_location/1)
    |> update_change(:summary, &SukhiFedi.HTML.sanitize/1)
    |> update_change(:fields, &cast_fields(&1, @max_remote_fields))
    |> validate_required([:username, :domain, :actor_uri])
  end

  @doc """
  Changeset for the badges an admin hands to a local account. The one gate
  for what reaches `roles`: at most 3 rows, each name plain text (escaped,
  1..30 chars), each color a `#rgb` / `#rrggbb` hex or "" (the client picks
  its default). Remote rows never pass through here.
  """
  def changeset_roles(account, rows) do
    account
    |> cast(%{roles: rows}, [:roles])
    |> update_change(:roles, &cast_roles/1)
  end

  @max_roles 3
  @max_role_name 30
  defp cast_roles(rows) when is_list(rows) do
    rows |> Enum.flat_map(&one_role/1) |> Enum.take(@max_roles)
  end

  defp cast_roles(_), do: []

  defp one_role(%{} = row) do
    name = row |> field_str("name") |> String.trim() |> String.slice(0, @max_role_name)
    color = row |> field_str("color") |> String.trim()

    case name do
      "" ->
        []

      _ ->
        [
          %{
            "name" => SukhiFedi.HTML.escape(name),
            "color" => if(Regex.match?(~r/\A#(?:[0-9a-fA-F]{3}|[0-9a-fA-F]{6})\z/, color), do: color, else: "")
          }
        ]
    end
  end

  defp one_role(_), do: []

  defp cut_location(v) when is_binary(v), do: String.slice(v, 0, @max_location)
  defp cut_location(v), do: v

  @doc """
  Changeset for the decorations mirrored from a remote Misskey-family
  origin. The one gate for what reaches `avatar_decorations`.
  """
  def changeset_decorations(account, rows) do
    account
    |> cast(%{avatar_decorations: rows}, [:avatar_decorations])
    |> update_change(:avatar_decorations, &cast_decorations/1)
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
      :indexable,
      :location,
      :birthday
    ])
    |> update_change(:fields, &cast_fields(&1, @max_fields))
    |> validate_length(:display_name, max: 100)
    |> validate_length(:location, max: @max_location)
    |> validate_length(:summary, max: 1024)
    |> render_summary()
  end

  # A local bio is Markdown, rendered once at write time through the same
  # `Markdown.to_html/1` a note takes (which sanitises last), so the bio gets
  # exactly the notes' formatting and `summary` stays the one HTML every
  # reader and every federated peer sees. The source rides along for editing.
  defp render_summary(changeset) do
    case get_change(changeset, :summary) do
      source when is_binary(source) ->
        changeset
        |> put_change(:summary_source, source)
        |> put_change(:summary, SukhiFedi.Markdown.to_html(source))

      _ ->
        changeset
    end
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
  # the remote mirror. Our own users keep at most 4 rows; a remote actor
  # keeps up to 16 (what Misskey allows — cutting it to our 4 hid the links
  # and handles the person put there). Each name is plain text (escaped,
  # like local note content) and each value is run through the shared bio
  # scrubber `HTML.sanitize/1` — never an inline second scrubber
  # (CODE_STYLE §0/§3). Blank-named rows are dropped.
  @max_field_name 255
  @max_field_value 512
  defp cast_fields(rows, max) when is_list(rows) do
    rows
    |> Enum.map(&one_field/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.take(max)
  end

  defp cast_fields(_, _max), do: []

  defp one_field(row) when is_map(row) do
    name = row |> field_str("name") |> String.slice(0, @max_field_name)
    value = row |> field_str("value") |> SukhiFedi.HTML.sanitize() |> String.slice(0, @max_field_value)

    case String.trim(name) do
      "" -> nil
      _ -> %{"name" => SukhiFedi.HTML.escape(name), "value" => value}
    end
  end

  defp one_field(_), do: nil

  # At most 4 decorations; the url must be http(s) (it is later proxied, never
  # fetched by a viewer's browser directly); angle is a turn (-0.5..0.5),
  # offsets a fraction of the icon size (-1..1), as Misskey defines them.
  @max_decorations 4
  defp cast_decorations(rows) when is_list(rows) do
    rows |> Enum.flat_map(&one_decoration/1) |> Enum.take(@max_decorations)
  end

  defp cast_decorations(_), do: []

  defp one_decoration(%{} = row) do
    url = Map.get(row, "url")

    case URI.parse(to_string(url)) do
      %URI{scheme: s, host: h} when s in ["http", "https"] and is_binary(h) and h != "" ->
        [
          %{
            "url" => url,
            "angle" => num(row, "angle", -0.5, 0.5),
            "flip_h" => Map.get(row, "flip_h") == true,
            "offset_x" => num(row, "offset_x", -1.0, 1.0),
            "offset_y" => num(row, "offset_y", -1.0, 1.0)
          }
        ]

      _ ->
        []
    end
  end

  defp one_decoration(_), do: []

  defp num(row, key, lo, hi) do
    v = Map.get(row, key)
    if is_number(v), do: v |> max(lo) |> min(hi) |> Kernel.*(1.0), else: 0.0
  end

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
