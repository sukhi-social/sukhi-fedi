# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiDelivery.PullFederation.NotifyWorker do
  @moduledoc """
  Sends one Pull Federation notification to one host:

      POST https://<host>/pull/v1/notify
      {"type":"PullNotification","origin":"<us>","heads":{"<actor uri>":<seq>}}

  `heads` has an entry for every local actor that has log rows this host has
  not been told about yet *and* that the host follows. It is HTTP-signed by
  one of those actors through `Delivery.Worker.post_signed/4` (the single
  signing path), so the receiver authenticates it exactly as it does an
  inbox POST.

  Outcomes:

    * `2xx` — `pull_peers.notified_through` advances to the newest row
      included; the failure count resets.
    * `429` — the peer's rate floor. Not a failure: the job snoozes for the
      `Retry-After` it asked for, capped.
    * `404`/`410`/`501` — the host does not (any longer) serve the endpoint.
      Counts as a failure and the backlog is pushed at once (`Fallback`).
    * anything else — a failure; Oban retries with backoff, and on the last
      attempt the backlog is pushed instead (`Fallback`). Either way an
      activity the host never pulls is delivered by push, never dropped.

  `failures` feeds the breaker in `Route`.
  """

  use Oban.Worker,
    queue: :federation,
    max_attempts: 6,
    unique: [period: 30, keys: [:host], states: [:available, :scheduled]]

  import Ecto.Query

  alias SukhiDelivery.Delivery.Worker
  alias SukhiDelivery.PullFederation.Fallback
  alias SukhiDelivery.Repo
  alias SukhiShared.PullStats

  @max_snooze 300

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"host" => host}} = job) do
    through = notified_through(host)

    case heads(host, through) do
      [] ->
        :ok

      heads ->
        send_notification(job, host, heads)
    end
  end

  defp send_notification(job, host, heads) do
    origin = SukhiDelivery.Config.domain!()
    through = heads |> Enum.map(& &1.max_id) |> Enum.max()
    signer = hd(heads).actor_uri

    body =
      JSON.encode!(%{
        "type" => "PullNotification",
        "origin" => origin,
        "heads" => Map.new(heads, &{&1.actor_uri, &1.seq})
      })

    url = endpoint(host)
    started = System.monotonic_time(:millisecond)

    result =
      if SukhiShared.UrlGuard.safe?(url),
        do: Worker.post_signed(url, signer, body, "application/json"),
        else: {:ok, %{status: 0, blocked: true}}

    ms = System.monotonic_time(:millisecond) - started

    case result do
      {:ok, %{status: status}} when status in 200..299 ->
        mark_ok(host, through)
        PullStats.bump("notify_sent", ms: ms, host: host)
        :ok

      {:ok, %{status: 429} = resp} ->
        PullStats.bump("notify_failed", host: host)
        {:snooze, retry_after(resp)}

      {:ok, %{status: status}} when status in [404, 410, 501] ->
        failed(host, "status #{status}")
        Fallback.push(host)
        :ok

      {:ok, %{blocked: true}} ->
        # Not a public https host: nothing we may talk to. Deliver by push,
        # which has its own guard and its own verdict.
        failed(host, "blocked egress host")
        Fallback.push(host)
        :ok

      other ->
        reason = describe(other)
        failed(host, reason)

        if job.attempt >= job.max_attempts do
          Fallback.push(host)
          :ok
        else
          {:error, reason}
        end
    end
  end

  # `/pull/v1/notify` at the host. The override is a test seam (a local
  # Bypass server is not https on the default port); nothing sets it in
  # production.
  defp endpoint(host) do
    case Application.get_env(:sukhi_delivery, :pull_notify_endpoint) do
      fun when is_function(fun, 1) -> fun.(host)
      _ -> "https://#{host}/pull/v1/notify"
    end
  end

  # The newest log row per followed local actor that this host has not been
  # told about: `{actor_uri, seq, max_id}`.
  defp heads(host, through) do
    domain = SukhiDelivery.Config.domain!()
    host = String.downcase(host)

    from(l in "pull_log",
      join: a in "accounts",
      on: a.id == l.account_id,
      where: l.id > ^through,
      where:
        fragment(
          "EXISTS (SELECT 1 FROM follows f WHERE f.followee_id = ? AND f.state = 'accepted' AND lower(split_part(f.follower_uri, '/', 3)) = ?)",
          l.account_id,
          ^host
        ),
      group_by: a.username,
      select: %{username: a.username, seq: max(l.seq), max_id: max(l.id)}
    )
    |> Repo.all()
    |> Enum.map(&Map.put(&1, :actor_uri, "https://#{domain}/users/#{&1.username}"))
  end

  defp notified_through(host) do
    Repo.one(from(p in "pull_peers", where: p.host == ^host, select: p.notified_through)) || 0
  end

  defp mark_ok(host, through) do
    Repo.query!(
      """
      INSERT INTO pull_peers (host, notified_through, notified_at, failures, last_error)
      VALUES ($1, $2, now(), 0, NULL)
      ON CONFLICT (host) DO UPDATE SET
        notified_through = GREATEST(pull_peers.notified_through, EXCLUDED.notified_through),
        notified_at = now(), failures = 0, last_error = NULL
      """,
      [host, through]
    )
  end

  defp failed(host, reason) do
    PullStats.bump("notify_failed", host: host)

    Repo.query!(
      """
      INSERT INTO pull_peers (host, notified_at, failures, last_error) VALUES ($1, now(), 1, $2)
      ON CONFLICT (host) DO UPDATE SET
        notified_at = now(), failures = pull_peers.failures + 1, last_error = EXCLUDED.last_error
      """,
      [host, String.slice(reason, 0, 300)]
    )
  end

  defp retry_after(%{headers: headers}) do
    value =
      case headers do
        %{"retry-after" => [v | _]} ->
          v

        %{"retry-after" => v} when is_binary(v) ->
          v

        list when is_list(list) ->
          Enum.find_value(list, fn {k, v} -> if String.downcase(k) == "retry-after", do: v end)

        _ ->
          nil
      end

    case value && Integer.parse(to_string(value)) do
      {n, _} when n > 0 -> min(n, @max_snooze)
      _ -> 5
    end
  end

  defp retry_after(_), do: 5

  defp describe({:ok, %{status: status}}), do: "status #{status}"
  defp describe({:error, reason}), do: inspect(reason)
  defp describe(other), do: inspect(other)
end
