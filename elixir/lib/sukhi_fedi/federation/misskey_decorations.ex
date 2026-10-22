# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Federation.MisskeyDecorations do
  @moduledoc """
  Avatar decorations of a remote Misskey-family account (Misskey, Sharkey,
  and other forks).

  ActivityPub carries no decoration: the Person document has `icon` only. The
  origin's own API does — `users/show` returns `avatarDecorations`, a list of
  `{id, url, angle, flipH, offsetX, offsetY}`. So this is a Misskey-API read,
  not federation, and it is strictly best effort: an origin that is not
  Misskey-shaped, is down, or has the endpoint closed simply leaves the
  account without a decoration. Nothing here is user-visible as an error.

  `parse/1` is pure and tolerant (forks differ in which keys they send);
  `refresh/1` is the only network path and passes `UrlGuard.safe?/1` before
  the request, with the body capped by `HttpFetch.capped_get/2`. Storage goes
  through `Account.changeset_decorations/2`, the one gate.
  """

  require Logger

  alias SukhiFedi.Fedi.HttpFetch
  alias SukhiFedi.Repo
  alias SukhiFedi.Schema.Account
  alias SukhiShared.UrlGuard

  @receive_timeout 10_000

  @doc "Decode a `users/show` body into decoration rows (possibly empty)."
  @spec parse(term()) :: [map()]
  def parse(%{"avatarDecorations" => rows}) when is_list(rows) do
    Enum.flat_map(rows, fn
      %{"url" => url} = row when is_binary(url) ->
        [
          %{
            "url" => url,
            "angle" => row["angle"],
            "flip_h" => row["flipH"],
            "offset_x" => row["offsetX"],
            "offset_y" => row["offsetY"]
          }
        ]

      _ ->
        []
    end)
  end

  def parse(_), do: []

  @doc """
  Fetch and store the decorations of a remote account. Returns `:ok` when
  the row is up to date (including "has none"), `{:error, reason}` when the
  origin could not be read — the stored value is then left untouched.
  """
  @spec refresh(Account.t()) :: :ok | {:error, term()}
  def refresh(%Account{domain: domain, username: username} = account)
      when is_binary(domain) and domain != "" do
    url = "https://#{domain}/api/users/show?" <> URI.encode_query(%{"username" => username})

    with true <- UrlGuard.safe?(url) || {:error, :unsafe_url},
         {:ok, %{status: 200, body: body}} when is_binary(body) <- get(url),
         {:ok, json} <- JSON.decode(body),
         {:ok, _} <- account |> Account.changeset_decorations(parse(json)) |> Repo.update() do
      :ok
    else
      {:error, reason} ->
        {:error, reason}

      {:ok, %{status: status}} ->
        {:error, {:http_status, status}}

      other ->
        {:error, other}
    end
  end

  def refresh(_), do: {:error, :not_remote}

  defp get(url) do
    HttpFetch.capped_get(url,
      headers: %{"accept" => "application/json"},
      redirect: false,
      finch: SukhiFedi.Finch,
      receive_timeout: @receive_timeout
    )
  end
end
