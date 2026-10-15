# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Federation.InboundArchive do
  @moduledoc """
  Archive verified inbound ActivityPub originals to the `inbound`
  object-storage bucket, and index them in `inbound_events` (Q10).

  The bytes the remote signed (`raw_body`) are the system of record:
  stored verbatim, zstd-compressed, content-addressed. The DB row is a
  thin time-ordered index that drives replay/rebuild.

  This runs off the inbox hot path — the controller enqueues an Oban
  job (`enqueue/4`) and returns 202 immediately; the PUT + index insert
  happen here. The job is durable (survives a crash) and retried, which
  is what makes the archive trustworthy as a record. rustfs being down
  isn't fatal — the job just retries; if S3 is unconfigured we no-op.

  Key: `inbound/<yyyy>/<mm>/<dd>/<sha256(raw_body)>.json.zst`. The date
  prefix gives lifecycle/sortability; the content hash dedups same-day
  retries. Idempotent: `inbound_events.body_sha256` is unique and the
  object key is content-addressed, so a re-run overwrites identical
  bytes and the insert is a no-op.
  """

  use Oban.Worker, queue: :inbound_archive, max_attempts: 5

  require Logger

  alias SukhiFedi.Repo
  alias SukhiFedi.Schema.InboundEvent

  # Archive density over speed — this is async and write-once.
  @zstd_level 19

  @doc """
  Enqueue an archive job for a verified inbound activity.

  `raw_body` is the exact signed bytes; `raw_json` the parsed map (for
  cheap actor/type/id extraction); `headers` the request headers (a
  small provenance subset is mirrored into S3 object metadata);
  `inbox_kind` is `"shared"` or `"user"`.
  """
  @spec enqueue(binary(), map(), map(), String.t()) ::
          {:ok, Oban.Job.t() | :archive_disabled} | {:error, term()}
  def enqueue(raw_body, raw_json, headers, inbox_kind)
      when is_binary(raw_body) and is_map(raw_json) do
    if s3_enabled?() do
      %{
        "raw_body" => raw_body,
        "actor_uri" => extract_actor(raw_json),
        "activity_type" => string_or_nil(raw_json["type"]),
        "activity_id" => string_or_nil(raw_json["id"]),
        "inbox" => inbox_kind,
        "received_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "http_date" => headers["date"],
        "digest" => headers["digest"]
      }
      |> __MODULE__.new()
      |> then(&Oban.insert(SukhiFedi.Oban, &1))
    else
      # No object store configured → archiving is a deliberate no-op. Don't
      # enqueue a job that would only no-op; tell the caller it was skipped (an
      # expected outcome, not a failure to warn about).
      {:ok, :archive_disabled}
    end
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"raw_body" => raw_body} = args}) do
    cond do
      not s3_enabled?() ->
        Logger.debug("inbound_archive: S3 not configured, skipping archive")
        :ok

      true ->
        sha = :crypto.hash(:sha256, raw_body) |> Base.encode16(case: :lower)
        archive(args, raw_body, sha)
    end
  end

  defp archive(args, raw_body, sha) do
    {:ok, received_at, _} = DateTime.from_iso8601(args["received_at"])
    key = object_key(received_at, sha)

    with {:ok, _} <- put_object(key, raw_body, args),
         {:ok, _} <- index(key, sha, received_at, args) do
      :ok
    end
  end

  defp put_object(key, raw_body, args) do
    bucket = inbound_bucket()
    compressed =
      raw_body
      |> :zstd.compress(%{compressionLevel: @zstd_level})
      |> IO.iodata_to_binary()

    meta =
      [
        {"actor", args["actor_uri"]},
        {"activity-type", args["activity_type"]},
        {"activity-id", args["activity_id"]},
        {"received-at", args["received_at"]},
        {"http-date", args["http_date"]},
        {"digest", args["digest"]}
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
        # down). The 202 was already sent; nothing user-facing blocks.
        Logger.warning("inbound_archive: put_object failed key=#{key} reason=#{inspect(reason)}")
        err
    end
  end

  defp index(key, sha, received_at, args) do
    %InboundEvent{}
    |> InboundEvent.changeset(%{
      received_at: received_at,
      actor_uri: args["actor_uri"],
      activity_type: args["activity_type"],
      activity_id: args["activity_id"],
      object_key: key,
      body_sha256: sha,
      inbox: args["inbox"]
    })
    |> Repo.insert(on_conflict: :nothing, conflict_target: :body_sha256)
  end

  defp object_key(%DateTime{} = dt, sha) do
    yyyy = dt.year |> Integer.to_string() |> String.pad_leading(4, "0")
    mm = dt.month |> Integer.to_string() |> String.pad_leading(2, "0")
    dd = dt.day |> Integer.to_string() |> String.pad_leading(2, "0")
    "inbound/#{yyyy}/#{mm}/#{dd}/#{sha}.json.zst"
  end

  # fedify inlines the resolved actor object into `actor` instead of a
  # bare id string for some activities — accept both shapes.
  defp extract_actor(%{"actor" => actor}), do: extract_uri(actor)
  defp extract_actor(_), do: nil

  defp extract_uri(uri) when is_binary(uri), do: uri
  defp extract_uri(%{"id" => id}) when is_binary(id), do: id
  defp extract_uri(_), do: nil

  defp string_or_nil(v) when is_binary(v), do: v
  defp string_or_nil(_), do: nil

  defp s3_enabled?, do: Application.get_env(:sukhi_fedi, :s3, [])[:enabled] == true

  defp inbound_bucket,
    do: Application.get_env(:sukhi_fedi, :s3, [])[:inbound_bucket] || "inbound"
end
