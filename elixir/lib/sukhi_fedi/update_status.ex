# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.UpdateStatus do
  @moduledoc """
  Read-only view of `status.json`, written by `sukhi-gitops-sync` on the box
  (see docs/OPS_UPDATE_PROPOSAL.ja.md §2). The gateway only reads it; nothing
  here can change what runs.

  `read/1` returns `nil` when the file is absent or unreadable, so local dev
  (no box) simply shows no section. A file whose `checked_at` is older than
  `@stale_after` (3× the 5-minute timer) is reported as `:stale` — the timer
  has stopped, so "up to date" can no longer be trusted.
  """

  @stale_after 15 * 60
  @default_path "/run/sukhi-gitops/status.json"

  @type t :: %{
          state: :up_to_date | :update_available | :rejected | :error | :stale,
          env: String.t() | nil,
          checked_at: String.t() | nil,
          applied: map() | nil,
          available: map() | nil,
          last_error: String.t() | nil
        }

  @spec path() :: String.t()
  def path, do: Application.get_env(:sukhi_fedi, :gitops_status_path) || @default_path

  @spec read(DateTime.t()) :: t() | nil
  def read(now \\ DateTime.utc_now()) do
    with {:ok, raw} <- File.read(path()),
         {:ok, %{"schema" => 1} = doc} <- Jason.decode(raw) do
      %{
        state: state(doc, now),
        env: doc["env"],
        checked_at: doc["checked_at"],
        applied: doc["applied"],
        available: doc["available"],
        last_error: doc["last_error"]
      }
    else
      _ -> nil
    end
  end

  defp state(doc, now) do
    if stale?(doc["checked_at"], now), do: :stale, else: known_state(doc["state"])
  end

  defp known_state("up_to_date"), do: :up_to_date
  defp known_state("update_available"), do: :update_available
  defp known_state("rejected"), do: :rejected
  defp known_state(_), do: :error

  defp stale?(checked_at, now) when is_binary(checked_at) do
    case DateTime.from_iso8601(checked_at) do
      {:ok, at, _} -> DateTime.diff(now, at) > @stale_after
      _ -> true
    end
  end

  defp stale?(_, _), do: true
end
