# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Federation.MisskeyDecorationsWorker do
  @moduledoc """
  Background read of a remote account's avatar decorations, so the actor
  upsert never waits on a second request to the origin. Quiet by design: a
  failure is logged at debug and not retried loudly — decorations are an
  ornament, and the next actor refresh tries again.
  """

  use Oban.Worker, queue: :preview, max_attempts: 1, unique: [period: 6 * 3600, keys: [:account_id]]

  require Logger

  alias SukhiFedi.Federation.MisskeyDecorations
  alias SukhiFedi.Repo
  alias SukhiFedi.Schema.Account

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"account_id" => id}}) do
    with %Account{} = account <- Repo.get(Account, id),
         {:error, reason} <- MisskeyDecorations.refresh(account) do
      Logger.debug("decorations: skipped #{account.actor_uri}: #{inspect(reason)}")
    end

    :ok
  end
end
