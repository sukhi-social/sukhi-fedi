# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Repo.Migrations.AddQuietUntilToAccounts do
  use Ecto.Migration

  @moduledoc """
  おやすみ — when this account does not want its phone woken.

  It lives on the account, not on the per-device push subscription, so
  turning it on quiets every device at once. NULL means "not quiet".

  It gates the doorbell and nothing else. The notification row is still
  written, still counted, still streamed to a screen that is already
  open — suppressing the *interruption* is honest, suppressing the
  *history* would be a lie. And when it ends nothing replays: what was
  missed is simply in the list, where it always was.
  """

  def change do
    alter table(:accounts) do
      add :quiet_until, :utc_datetime
    end
  end
end
