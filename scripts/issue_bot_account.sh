#!/usr/bin/env bash
# Issue a local bot account on the production gateway.
# Credentials are written to OUTPUT_FILE (mode 600), not to stdout.
#
# Usage:
#   bash scripts/issue_bot_account.sh [username] [display_name]

set -euo pipefail

USERNAME="${1:-shiro_mudita}"
DISPLAY_NAME="${2:-$USERNAME}"
SCOPES="read write follow"
HOST="rocky@${DEPLOY_HOST:?set DEPLOY_HOST to the box ip/hostname}"
CONTAINER="${DEPLOY_CONTAINER:-sukhi-fedi-gateway}"
OUTPUT_FILE="${HOME}/.sukhi-fedi-${USERNAME}-credentials"

EVAL_CODE='
alias SukhiFedi.{Repo, OAuth}
alias SukhiFedi.Schema.Account
alias SukhiFedi.Addons.NodeinfoMonitor.KeyGen

uname = System.get_env("BOT_USERNAME")
dname = System.get_env("BOT_DISPLAY_NAME")
scopes = System.get_env("BOT_SCOPES")

keys = KeyGen.generate()
pass_hash = Argon2.hash_pwd_salt(:crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false))

account =
  case Repo.get_by(Account, username: uname) do
    nil ->
      {:ok, a} = Repo.insert(Account.changeset_local(%Account{}, %{
        username: uname,
        display_name: dname,
        password_hash: pass_hash,
        public_key_pem: keys.public_pem,
        public_key_jwk: keys.public_jwk,
        private_key_jwk: keys.private_jwk
      }))
      Repo.update!(Ecto.Changeset.change(a, is_bot: true))
      IO.puts("ACCOUNT_STATUS=created")
      a
    existing ->
      IO.puts("ACCOUNT_STATUS=already_exists")
      existing
  end

{:ok, %{app: app, client_secret: client_secret}} = OAuth.register_app(%{
  "name" => uname, "redirect_uris" => "urn:ietf:wg:oauth:2.0:oob", "scopes" => scopes
})

{:ok, token} = OAuth.issue_initial_token(app.id, account.id, scopes)

IO.puts("USERNAME=" <> uname)
IO.puts("CLIENT_ID=" <> app.client_id)
IO.puts("CLIENT_SECRET=" <> client_secret)
IO.puts("ACCESS_TOKEN=" <> token.access_token)
IO.puts("REFRESH_TOKEN=" <> (token.refresh_token || ""))
IO.puts("SCOPE=" <> scopes)
'

echo "Issuing bot account '${USERNAME}' on ${HOST} ..." >&2

ssh "${HOST}" \
  "BOT_USERNAME='${USERNAME}' BOT_DISPLAY_NAME='${DISPLAY_NAME}' BOT_SCOPES='${SCOPES}' \
   docker exec -e BOT_USERNAME='${USERNAME}' -e BOT_DISPLAY_NAME='${DISPLAY_NAME}' -e BOT_SCOPES='${SCOPES}' \
   ${CONTAINER} bin/sukhi_fedi eval '${EVAL_CODE}'" \
  > "${OUTPUT_FILE}" 2>/dev/null

chmod 600 "${OUTPUT_FILE}"
echo "Done. Credentials saved to ${OUTPUT_FILE}" >&2
