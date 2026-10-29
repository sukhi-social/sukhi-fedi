# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.RawStore.S3 do
  @moduledoc """
  Blobs in an S3-compatible bucket, key `raw/sha256/<first two hex>/<hex>`.
  The bucket may be the media bucket (a separate prefix) or its own; opts:
  `:bucket` (required), `:request` (a function `ExAws.Operation -> result`,
  for tests; default `ExAws.request/1`).
  """

  @behaviour SukhiFedi.RawStore.Backend

  @prefix "raw/sha256/"

  @impl true
  def put(key, body, opts) do
    case request(
           opts,
           ExAws.S3.put_object(bucket(opts), object_key(key), body,
             content_type: "application/zstd"
           )
         ) do
      {:ok, _} -> :ok
      {:error, _} = err -> err
    end
  end

  @impl true
  def get(key, opts) do
    case request(opts, ExAws.S3.get_object(bucket(opts), object_key(key))) do
      {:ok, %{body: body}} -> {:ok, body}
      {:error, {:http_error, 404, _}} -> {:error, :missing}
      {:error, _} = err -> err
    end
  end

  @impl true
  def exists?(key, opts) do
    match?({:ok, _}, request(opts, ExAws.S3.head_object(bucket(opts), object_key(key))))
  end

  @impl true
  def delete(key, opts) do
    case request(opts, ExAws.S3.delete_object(bucket(opts), object_key(key))) do
      {:ok, _} -> :ok
      {:error, _} = err -> err
    end
  end

  @impl true
  def list_older_than(unix, opts) do
    bucket(opts)
    |> ExAws.S3.list_objects_v2(prefix: @prefix)
    |> ExAws.stream!(Keyword.take(opts, [:config]))
    |> Enum.filter(&(last_modified(&1) <= unix))
    |> Enum.map(&ref_of(&1.key))
    |> then(&{:ok, &1})
  rescue
    e -> {:error, e}
  end

  @doc false
  def object_key("sha256:" <> hex), do: @prefix <> String.slice(hex, 0, 2) <> "/" <> hex

  defp ref_of(@prefix <> <<_::binary-size(2), "/", hex::binary>>), do: "sha256:" <> hex

  defp last_modified(%{last_modified: lm}) do
    {:ok, dt, _} = DateTime.from_iso8601(lm)
    DateTime.to_unix(dt)
  end

  defp bucket(opts), do: Keyword.fetch!(opts, :bucket)

  defp request(opts, op), do: Keyword.get(opts, :request, &ExAws.request/1).(op)
end
