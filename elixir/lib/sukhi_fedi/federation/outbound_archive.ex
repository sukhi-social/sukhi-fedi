# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Federation.OutboundArchive do
  @moduledoc """
  Archive the bytes we actually delivered to a remote inbox to the
  `outbound` object-storage bucket, and index them in `outbound_events`.
  The mirror of `SukhiFedi.Federation.InboundArchive` — incoming originals
  are kept verbatim, so keep the outgoing ones too. The `outbox` table holds
  only intent and is pruned; this is the durable record of what we sent.

  Cross-node: the delivery node (`SukhiDelivery.Delivery.Worker`) has no S3
  dependencies, so it doesn't archive inline. After a terminal POST it
  inserts an Oban job into the shared `oban_jobs` table naming this worker as
  a string on the `outbound_archive` queue — only the gateway (which has
  ex_aws + the S3 config) polls that queue, so the PUT + index happen
  here. The job is durable and retried, like the inbound archive.

  Key: `outbound/<yyyy>/<mm>/<dd>/<sha256(body)>.json.zst`. The body is
  identical across every recipient inbox of one activity (only the signature
  headers differ, which we don't store — a deferred byte-perfect variant), so
  content-addressing collapses a fan-out to one object. The index row is per
  `(activity_id, inbox_url)` and carries the remote's response status;
  idempotent on that unique key, so a retried delivery's insert is a no-op.
  """

  use Oban.Worker, queue: :outbound_archive, max_attempts: 5

  require Logger

  alias SukhiFedi.Repo
  alias SukhiFedi.Schema.OutboundEvent

  # Archive density over speed — async and write-once, same as inbound.
  @zstd_level 19

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"body" => body} = args}) when is_binary(body) do
    cond do
      not s3_enabled?() ->
        Logger.debug("outbound_archive: S3 not configured, skipping archive")
        :ok

      true ->
        sha = :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)
        archive(args, body, sha)
    end
  end

  defp archive(args, body, sha) do
    {:ok, delivered_at, _} = DateTime.from_iso8601(args["delivered_at"])
    key = object_key(delivered_at, sha)

    with {:ok, _} <- put_object(key, body, args),
         {:ok, _} <- index(key, sha, delivered_at, args) do
      :ok
    end
  end

  defp put_object(key, body, args) do
    bucket = outbound_bucket()
    compressed =
      body
      |> :zstd.compress(%{compressionLevel: @zstd_level})
      |> IO.iodata_to_binary()

    meta =
      [
        {"actor", args["actor_uri"]},
        {"activity-id", args["activity_id"]},
        {"inbox-url", args["inbox_url"]},
        {"status", args["status"]},
        {"response-status", args["response_status"] && to_string(args["response_status"])},
        {"delivered-at", args["delivered_at"]}
      ]
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)

    bucket
    |> ExAws.S3.put_object(key, compressed, content_type: "application/zstd", meta: meta)
    |> ExAws.request()
    |> case do
      {:ok, resp} ->
        {:ok, resp}

      {:error, reason} = err ->
        # Returning the error lets Oban retry (rustfs may be transiently
        # down). The delivery already happened; nothing user-facing blocks.
        Logger.warning("outbound_archive: put_object failed key=#{key} reason=#{inspect(reason)}")
        err
    end
  end

  defp index(key, sha, delivered_at, args) do
    %OutboundEvent{}
    |> OutboundEvent.changeset(%{
      delivered_at: delivered_at,
      actor_uri: args["actor_uri"],
      activity_id: args["activity_id"],
      inbox_url: args["inbox_url"],
      status: args["status"],
      response_status: args["response_status"],
      object_key: key,
      body_sha256: sha
    })
    |> Repo.insert(on_conflict: :nothing, conflict_target: [:activity_id, :inbox_url])
  end

  defp object_key(%DateTime{} = dt, sha) do
    yyyy = dt.year |> Integer.to_string() |> String.pad_leading(4, "0")
    mm = dt.month |> Integer.to_string() |> String.pad_leading(2, "0")
    dd = dt.day |> Integer.to_string() |> String.pad_leading(2, "0")
    "outbound/#{yyyy}/#{mm}/#{dd}/#{sha}.json.zst"
  end

  defp s3_enabled?, do: Application.get_env(:sukhi_fedi, :s3, [])[:enabled] == true

  defp outbound_bucket,
    do: Application.get_env(:sukhi_fedi, :s3, [])[:outbound_bucket] || "outbound"
end
