# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiDelivery.PullFederation.Peers do
  @moduledoc """
  The one writer of `pull_peers`: how far a host has been told, and how its
  last notification went.

  Each call makes sure the host's row exists, then updates it with plain
  statements, so it is the same code on every store. `notified_through` only
  ever moves forward.
  """

  import Ecto.Query

  alias SukhiDelivery.Repo

  @doc "Record that `host` has been told about everything up to log row `through`."
  @spec advance(String.t(), integer()) :: :ok
  def advance(host, through) do
    ensure(host)
    forward(host, through)
    :ok
  end

  @doc "A notification went through: advance, and reset the failure count."
  @spec ok(String.t(), integer()) :: :ok
  def ok(host, through) do
    ensure(host)
    forward(host, through)

    from(p in "pull_peers", where: p.host == ^host)
    |> Repo.update_all(set: [notified_at: now(), failures: 0, last_error: nil])

    :ok
  end

  @doc "A notification failed: count it and keep why."
  @spec failed(String.t(), String.t()) :: :ok
  def failed(host, reason) do
    ensure(host)

    from(p in "pull_peers", where: p.host == ^host)
    |> Repo.update_all(
      set: [notified_at: now(), last_error: String.slice(reason, 0, 300)],
      inc: [failures: 1]
    )

    :ok
  end

  defp ensure(host) do
    Repo.insert_all("pull_peers", [%{host: host}],
      on_conflict: :nothing,
      conflict_target: [:host]
    )
  end

  defp forward(host, through) do
    from(p in "pull_peers", where: p.host == ^host and p.notified_through < ^through)
    |> Repo.update_all(set: [notified_through: through])
  end

  defp now, do: DateTime.utc_now() |> DateTime.to_naive()
end
