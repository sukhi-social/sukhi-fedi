# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.RawStore.Config do
  @moduledoc """
  The knobs of `SukhiFedi.RawStore`, read in one place. `from_env/1` takes a
  map so tests need no real environment.

      SUKHI_RAW_BACKEND     sqlite (default) | s3
      SUKHI_RAW_INLINE_MAX  bytes kept on the entity itself (default 4096)
      SUKHI_RAW_GRACE_S     age before an unreferenced blob may be collected (default 86400)
      SUKHI_RAW_BUCKET      s3 only: bucket (default: S3_BUCKET, then "media")
  """

  defstruct backend: SukhiFedi.RawStore.SQLite,
            backend_opts: [],
            inline_max: 4096,
            grace_s: 86_400

  @type t :: %__MODULE__{
          backend: module(),
          backend_opts: keyword(),
          inline_max: non_neg_integer(),
          grace_s: non_neg_integer()
        }

  @spec default() :: t()
  def default, do: %__MODULE__{}

  @doc """
  The configuration of the running node: `config :sukhi_fedi, SukhiFedi.RawStore`
  if set (tests), else read once from the environment and remembered.
  A bad value raises at first use rather than being quietly replaced.
  """
  @spec current() :: t()
  def current do
    case Application.fetch_env(:sukhi_fedi, SukhiFedi.RawStore) do
      {:ok, %__MODULE__{} = config} ->
        config

      :error ->
        case :persistent_term.get({__MODULE__, :env}, nil) do
          nil ->
            {:ok, config} = from_env(System.get_env()) |> unwrap!()
            :persistent_term.put({__MODULE__, :env}, config)
            config

          config ->
            config
        end
    end
  end

  defp unwrap!({:ok, _} = ok), do: ok
  defp unwrap!({:error, msg}), do: raise(ArgumentError, msg)

  @spec from_env(%{optional(String.t()) => String.t()}) :: {:ok, t()} | {:error, String.t()}
  def from_env(env) do
    with {:ok, backend, opts} <- backend(env),
         {:ok, inline_max} <- int(env, "SUKHI_RAW_INLINE_MAX", 4096, 0),
         {:ok, grace_s} <- int(env, "SUKHI_RAW_GRACE_S", 86_400, 0) do
      {:ok,
       %__MODULE__{backend: backend, backend_opts: opts, inline_max: inline_max, grace_s: grace_s}}
    end
  end

  defp backend(env) do
    case Map.get(env, "SUKHI_RAW_BACKEND", "sqlite") do
      "sqlite" ->
        {:ok, SukhiFedi.RawStore.SQLite, []}

      "s3" ->
        bucket = env["SUKHI_RAW_BUCKET"] || env["S3_BUCKET"] || "media"
        {:ok, SukhiFedi.RawStore.S3, [bucket: bucket]}

      other ->
        {:error, "SUKHI_RAW_BACKEND must be sqlite or s3, got #{inspect(other)}"}
    end
  end

  defp int(env, name, default, min) do
    case Map.fetch(env, name) do
      :error ->
        {:ok, default}

      {:ok, v} ->
        case Integer.parse(v) do
          {n, ""} when n >= min -> {:ok, n}
          _ -> {:error, "#{name} must be an integer >= #{min}, got #{inspect(v)}"}
        end
    end
  end
end
