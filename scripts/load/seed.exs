# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Fills an empty dev database with enough to make the timelines do real work:
# local accounts, a few posts each, and one viewer who follows most of them.
# Run from combined/ after `mix sukhi.migrate`:
#
#   LOAD_TOKEN_FILE=/tmp/token mix run ../scripts/load/seed.exs
#
# One bearer token per account (for `run.mjs --token a,b,c`), one per line,
# is written to $LOAD_TOKEN_FILE. Not for production: it creates accounts with a known
# password.
alias SukhiFedi.{LocalAccounts, Notes, Repo}
alias SukhiFedi.Schema.Follow

accounts_n = String.to_integer(System.get_env("SEED_ACCOUNTS", "100"))
posts_each = String.to_integer(System.get_env("SEED_POSTS", "10"))
token_file = System.fetch_env!("LOAD_TOKEN_FILE")

accounts =
  for i <- 0..(accounts_n - 1) do
    {:ok, a} = LocalAccounts.create_admin("load#{i}", "loadtest-password-#{i}")
    a
  end

for a <- accounts, n <- 1..posts_each do
  {:ok, _} = Notes.create_status(a, %{"status" => "load test post #{n} from #{a.username}"})
end

# Everyone is a viewer: each follows the next two thirds of the ring, so every
# home timeline has work to do, and each has its own token (the api counts
# 300 requests per token per 5 minutes, which one shared token would hit).
domain = SukhiFedi.Config.domain!()
now = DateTime.utc_now() |> DateTime.truncate(:second)
count = length(accounts)
follow_n = div(count * 2, 3)
indexed = Enum.with_index(accounts)

rows =
  for {viewer, i} <- indexed, j <- 1..follow_n do
    {followee, _} = Enum.at(indexed, rem(i + j, count))

    %{
      follower_uri: "https://#{domain}/users/#{viewer.username}",
      followee_id: followee.id,
      state: "accepted",
      created_at: now
    }
  end

rows |> Enum.chunk_every(1000) |> Enum.each(&Repo.insert_all(Follow, &1))

tokens =
  for a <- accounts do
    {:ok, %{token: token}} =
      LocalAccounts.issue_personal_token(a.id, %{"name" => "load", "expires_in_days" => 1})

    token
  end

File.write!(token_file, Enum.join(tokens, "\n"))
IO.puts("seeded #{count} accounts x #{posts_each} posts; each follows #{follow_n}; #{count} tokens")
