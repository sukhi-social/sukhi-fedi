# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Fills an empty dev database with enough to make the timelines do real work:
# local accounts, a few posts each, and one viewer who follows most of them.
# Run from combined/ after `mix sukhi.migrate`:
#
#   LOAD_TOKEN_FILE=/tmp/token mix run ../scripts/load/seed.exs
#
# The viewer's bearer token (for `run.mjs --token`) is written to
# $LOAD_TOKEN_FILE. Not for production: it creates accounts with a known
# password.
alias SukhiFedi.{LocalAccounts, Notes, Repo}
alias SukhiFedi.Schema.Follow

accounts_n = String.to_integer(System.get_env("SEED_ACCOUNTS", "60"))
posts_each = String.to_integer(System.get_env("SEED_POSTS", "20"))
token_file = System.fetch_env!("LOAD_TOKEN_FILE")

accounts =
  for i <- 0..(accounts_n - 1) do
    {:ok, a} = LocalAccounts.create_admin("load#{i}", "loadtest-password-#{i}")
    a
  end

for a <- accounts, n <- 1..posts_each do
  {:ok, _} = Notes.create_status(a, %{"status" => "load test post #{n} from #{a.username}"})
end

[viewer | others] = accounts
domain = SukhiFedi.Config.domain!()
now = DateTime.utc_now() |> DateTime.truncate(:second)

Repo.insert_all(
  Follow,
  for(o <- Enum.take(others, div(accounts_n * 2, 3)),
    do: %{
      follower_uri: "https://#{domain}/users/#{viewer.username}",
      followee_id: o.id,
      state: "accepted",
      created_at: now
    }
  )
)

{:ok, %{token: token}} =
  LocalAccounts.issue_personal_token(viewer.id, %{"name" => "load", "expires_in_days" => 1})

File.write!(token_file, token)
IO.puts("seeded #{accounts_n} accounts x #{posts_each} posts; viewer follows #{div(accounts_n * 2, 3)}")
