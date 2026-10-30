# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.AccountPorter.FollowWorker do
  @moduledoc """
  One follow from an imported list (`SukhiFedi.AccountPorter`). The job row
  is the state: it is scheduled at its place in the queue, so the list goes
  out at a steady pace, and it survives a restart and retries a lookup that
  failed. An address that cannot be found after the attempts is discarded.
  """

  use Oban.Worker, queue: :import, max_attempts: 3

  alias SukhiFedi.{Accounts, Repo, Social}
  alias SukhiFedi.Schema.Account

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"account_id" => account_id, "address" => address}}) do
    with %Account{} = account <- Repo.get(Account, account_id),
         {:ok, %Account{} = target} <- Accounts.lookup_by_acct(address, resolve: true) do
      case Social.request_follow(account, target.id) do
        {:ok, _follow} -> :ok
        {:error, :self_follow} -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      # The account that asked is gone: nothing to follow for.
      nil -> {:cancel, :account_gone}
      {:error, reason} -> {:error, reason}
    end
  end
end
