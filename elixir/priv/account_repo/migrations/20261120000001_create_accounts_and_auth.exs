# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.AccountRepo.Migrations.CreateAccountsAndAuth do
  @moduledoc false
  # The accounts-and-auth tables, as they stand. Taken from a database the
  # earlier migrations had been run on (not from the Datalevin catalog, which keeps
  # no varchar lengths and no non-unique indexes). A change from here is a new
  # migration, by hand.
  use Ecto.Migration

  def change do
    create table(:accounts, primary_key: false) do
      add :id, :bigserial, primary_key: true
      add :username, :text, null: false
      add :display_name, :text
      add :summary, :text
      add :created_at, :"timestamp(0)", default: fragment("now()"), null: false
      add :private_key_jwk, :jsonb
      add :public_key_jwk, :jsonb
      add :avatar_url, :text
      add :banner_url, :text
      add :suspended_at, :"timestamp(0)"
      add :suspended_by_id, references(:accounts, on_delete: :nilify_all, type: :bigint)
      add :suspension_reason, :text
      add :is_admin, :boolean, default: false, null: false
      add :public_key_pem, :text
      add :is_bot, :boolean, default: false, null: false
      add :monitored_domain, :string
      add :domain, :text
      add :actor_uri, :text
      add :inbox_url, :text
      add :shared_inbox_url, :text
      add :public_key_id, :text
      add :last_fetched_at, :"timestamp(0)"
      add :email, :string
      add :password_hash, :string
      add :locked, :boolean, default: false, null: false
      add :emojis, {:array, :jsonb}, default: fragment("ARRAY[]::jsonb[]"), null: false
      add :ed25519_private_key_jwk, :jsonb
      add :ed25519_public_multibase, :string
      add :email_verified_at, :"timestamp(0)"
      add :totp_secret, :binary
      add :totp_enabled_at, :"timestamp(0)"
      add :totp_last_used_step, :bigint
      add :fields, :jsonb, default: fragment("'[]'::jsonb"), null: false
      add :aliases, {:array, :text}, default: fragment("ARRAY[]::text[]"), null: false
      add :moved_to_uri, :text
      add :discoverable, :boolean, default: false, null: false
      add :indexable, :boolean, default: false, null: false
      add :quiet_until, :"timestamp(0)"
      add :backfill_state, :text
      add :backfill_attempted_at, :"timestamp(0)"
      add :backfill_mirrored, :integer, default: 0, null: false
      add :backfill_error, :text
      add :avatar_decorations, {:array, :jsonb}, default: fragment("ARRAY[]::jsonb[]"), null: false
      add :summary_source, :text
      add :roles, {:array, :jsonb}, default: fragment("ARRAY[]::jsonb[]"), null: false
      add :location, :string
      add :birthday, :date
      add :deleted_at, :"timestamp(0)"
      add :notification_hold_minutes, :integer
      add :notification_grouping, :boolean, default: false, null: false
      add :home_filter, :string
      add :boost_hide_name, :boolean, default: false, null: false
      add :translate_reads, :text
      add :translate_learns, :text
      add :translate_engine, :string
      add :translate_deepl_key, :binary
      add :translate_deepl_key_hint, :string
      add :translate_auto, :boolean, default: false, null: false
    end
    create unique_index(:accounts, [:actor_uri], name: :accounts_actor_uri_index, where: "(actor_uri IS NOT NULL)")
    create index(:accounts, [:backfill_state], name: :accounts_backfill_state_index, where: "((backfill_state IS NULL) OR (backfill_state = 'failed'::text))")
    create index(:accounts, [:is_bot], name: :accounts_is_bot_index)
    create unique_index(:accounts, ["lower(email)"], name: :accounts_local_email_index, where: "((domain IS NULL) AND (email IS NOT NULL) AND (email_verified_at IS NOT NULL))")
    create unique_index(:accounts, [:username], name: :accounts_local_username_index, where: "(domain IS NULL)")
    create unique_index(:accounts, [:monitored_domain], name: :accounts_monitored_domain_index, where: "(monitored_domain IS NOT NULL)")
    create index(:accounts, [:domain], name: :accounts_remote_domain_index, where: "(domain IS NOT NULL)")
    create index(:accounts, [:suspended_at], name: :accounts_suspended_at_index)
    create index(:accounts, [:username, :domain], name: :accounts_username_domain_index)

    create table(:oauth_apps, primary_key: false) do
      add :id, :bigserial, primary_key: true
      add :client_id, :text, null: false
      add :client_secret_hash, :text, null: false
      add :name, :text, null: false
      add :redirect_uri, :text, null: false
      add :scopes, :text, default: "read", null: false
      add :website, :text
      add :owner_account_id, references(:accounts, on_delete: :nilify_all, type: :bigint)
      add :created_at, :"timestamp(0)", default: fragment("now()"), null: false
    end
    create unique_index(:oauth_apps, [:client_id], name: :oauth_apps_client_id_index)
    create index(:oauth_apps, [:owner_account_id], name: :oauth_apps_owner_account_id_index)

    create table(:invite_codes, primary_key: false) do
      add :id, :bigserial, primary_key: true
      add :code, :string, null: false
      add :issued_by_id, references(:accounts, on_delete: :nilify_all, type: :bigint)
      add :expires_at, :"timestamp(0)"
      add :note, :string
      add :created_at, :"timestamp(0)", null: false
      add :on_behalf_of_id, references(:accounts, on_delete: :nilify_all, type: :bigint)
      add :max_uses, :integer, default: 1, null: false
      add :uses_count, :integer, default: 0, null: false
    end
    create unique_index(:invite_codes, [:code], name: :invite_codes_code_index)

    create table(:sessions, primary_key: false) do
      add :id, :bigserial, primary_key: true
      add :account_id, references(:accounts, on_delete: :delete_all, type: :bigint), null: false
      add :token_hash, :text, null: false
      add :expires_at, :"timestamp(0)", null: false
      add :created_at, :"timestamp(0)", default: fragment("now()"), null: false
      add :ip_text, :text
      add :user_agent, :text
      add :last_seen_at, :"timestamp(0)"
    end
    create index(:sessions, [:account_id], name: :sessions_account_id_index)
    create index(:sessions, [:expires_at], name: :sessions_expires_at_index)
    create unique_index(:sessions, [:token_hash], name: :sessions_token_hash_index)

    create table(:oauth_access_tokens, primary_key: false) do
      add :id, :bigserial, primary_key: true
      add :token_hash, :text, null: false
      add :refresh_token_hash, :text
      add :app_id, references(:oauth_apps, on_delete: :delete_all, type: :bigint), null: false
      add :account_id, references(:accounts, on_delete: :delete_all, type: :bigint)
      add :scopes, :text, null: false
      add :expires_at, :"timestamp(0)"
      add :revoked_at, :"timestamp(0)"
      add :last_used_at, :"timestamp(0)"
      add :created_at, :"timestamp(0)", default: fragment("now()"), null: false
    end
    create index(:oauth_access_tokens, [:account_id], name: :oauth_access_tokens_account_id_index)
    create index(:oauth_access_tokens, [:app_id], name: :oauth_access_tokens_app_id_index)
    create unique_index(:oauth_access_tokens, [:refresh_token_hash], name: :oauth_access_tokens_refresh_token_hash_index, where: "(refresh_token_hash IS NOT NULL)")
    create unique_index(:oauth_access_tokens, [:token_hash], name: :oauth_access_tokens_token_hash_index)

    create table(:oauth_authorization_codes, primary_key: false) do
      add :id, :bigserial, primary_key: true
      add :code_hash, :text, null: false
      add :app_id, references(:oauth_apps, on_delete: :delete_all, type: :bigint), null: false
      add :account_id, references(:accounts, on_delete: :delete_all, type: :bigint), null: false
      add :redirect_uri, :text, null: false
      add :scopes, :text, null: false
      add :expires_at, :"timestamp(0)", null: false
      add :used_at, :"timestamp(0)"
      add :created_at, :"timestamp(0)", default: fragment("now()"), null: false
    end
    create index(:oauth_authorization_codes, [:app_id], name: :oauth_authorization_codes_app_id_index)
    create unique_index(:oauth_authorization_codes, [:code_hash], name: :oauth_authorization_codes_code_hash_index)
    create index(:oauth_authorization_codes, [:expires_at], name: :oauth_authorization_codes_expires_at_index)

    create table(:webauthn_credentials, primary_key: false) do
      add :id, :bigserial, primary_key: true
      add :account_id, references(:accounts, on_delete: :delete_all, type: :bigint), null: false
      add :credential_id, :string, null: false
      add :cose_key, :binary, null: false
      add :sign_count, :bigint, default: 0, null: false
      add :nickname, :string
      add :last_used_at, :"timestamp(0)"
      add :created_at, :"timestamp(0)", null: false
    end
    create index(:webauthn_credentials, [:account_id], name: :webauthn_credentials_account_id_index)
    create unique_index(:webauthn_credentials, [:credential_id], name: :webauthn_credentials_credential_id_index)

    create table(:webauthn_challenges, primary_key: false) do
      add :id, :bigserial, primary_key: true
      add :ref, :string, null: false
      add :account_id, references(:accounts, on_delete: :delete_all, type: :bigint)
      add :purpose, :string, null: false
      add :challenge, :binary, null: false
      add :expires_at, :"timestamp(0)", null: false
      add :created_at, :"timestamp(0)", null: false
    end
    create unique_index(:webauthn_challenges, [:ref], name: :webauthn_challenges_ref_index)

    create table(:email_codes, primary_key: false) do
      add :id, :bigserial, primary_key: true
      add :account_id, references(:accounts, on_delete: :delete_all, type: :bigint)
      add :email, :string, null: false
      add :purpose, :string, null: false
      add :code_hash, :string, null: false
      add :attempts, :integer, default: 0, null: false
      add :expires_at, :"timestamp(0)", null: false
      add :created_at, :"timestamp(0)", null: false
    end
    create unique_index(:email_codes, [:account_id, :purpose], name: :email_codes_account_id_purpose_index)
    create unique_index(:email_codes, ["lower(email)", :purpose], name: :email_codes_signup_index, where: "(account_id IS NULL)")

    create table(:invite_code_uses, primary_key: false) do
      add :id, :bigserial, primary_key: true
      add :invite_code_id, references(:invite_codes, on_delete: :delete_all, type: :bigint), null: false
      add :account_id, references(:accounts, on_delete: :nilify_all, type: :bigint)
      add :used_at, :"timestamp(0)", null: false
    end
    create unique_index(:invite_code_uses, [:invite_code_id, :account_id], name: :invite_code_uses_invite_code_id_account_id_index)
    create index(:invite_code_uses, [:invite_code_id], name: :invite_code_uses_invite_code_id_index)

    create table(:join_applications, primary_key: false) do
      add :id, :bigserial, primary_key: true
      add :receipt, :string, size: 16, null: false
      add :email, :string, size: 254, null: false
      add :call_name, :string, size: 80
      add :found, :text
      add :hope, :text
      add :lang, :string, size: 8
      add :check_on, :date
      add :claim_hash, :string, size: 64, null: false
      add :edit_hash, :string, size: 64
      add :confirmed_at, :"timestamp(0)"
      add :created_at, :"timestamp(0)", null: false
      add :updated_at, :"timestamp(0)", null: false
    end
    create unique_index(:join_applications, [:claim_hash], name: :join_applications_claim_hash_index)
    create index(:join_applications, [:confirmed_at, :created_at], name: :join_applications_confirmed_at_created_at_index)
    create unique_index(:join_applications, [:edit_hash], name: :join_applications_edit_hash_index)
    create unique_index(:join_applications, [:receipt], name: :join_applications_receipt_index)
  end
end
