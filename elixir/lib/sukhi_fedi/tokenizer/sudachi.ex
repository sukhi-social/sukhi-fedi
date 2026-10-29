# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Tokenizer.Sudachi do
  @moduledoc """
  Japanese segmentation by a Sudachi service reached over HTTP.

  Contract with the service (it can run beside the gateway or elsewhere):

      POST {SUKHI_SUDACHI_URL}/segment   {"text": "...", "mode": "A"|"B"|"C"}
      → 200 {"tokens": ["日本語", "の", "猫"]}

  Mode `A` (shortest units) is the default: a search for a short word still
  finds a longer compound that contains it. Only the request shape is fixed
  here; which Sudachi server answers it is left open.

  opts: `:url` (default `SUKHI_SUDACHI_URL`), `:mode`, `:timeout` (ms, default
  2000), `:request` (a function for tests: `(url, body, timeout) -> {:ok, map} | {:error, term}`).
  """

  @behaviour SukhiFedi.Tokenizer

  @impl true
  def segment(text, opts) do
    with {:ok, url} <- url(opts),
         {:ok, %{"tokens" => tokens}} when is_list(tokens) <- post(url <> "/segment", text, opts),
         true <- Enum.all?(tokens, &is_binary/1) do
      {:ok, tokens |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == "")) |> Enum.join(" ")}
    else
      {:ok, _} -> {:error, :bad_response}
      false -> {:error, :bad_response}
      {:error, _} = err -> err
    end
  end

  defp url(opts) do
    case Keyword.get(opts, :url) || System.get_env("SUKHI_SUDACHI_URL") do
      nil -> {:error, :not_configured}
      url -> {:ok, String.trim_trailing(url, "/")}
    end
  end

  defp post(url, text, opts) do
    body = %{"text" => text, "mode" => Keyword.get(opts, :mode, "A")}
    timeout = Keyword.get(opts, :timeout, 2000)

    case Keyword.get(opts, :request) do
      nil ->
        case Req.post(url, json: body, receive_timeout: timeout, retry: false) do
          {:ok, %Req.Response{status: 200, body: %{} = resp}} -> {:ok, resp}
          {:ok, %Req.Response{status: status}} -> {:error, {:http, status}}
          {:error, reason} -> {:error, reason}
        end

      fun ->
        fun.(url, body, timeout)
    end
  end
end
