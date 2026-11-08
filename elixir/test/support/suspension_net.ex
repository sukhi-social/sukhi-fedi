# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.SuspensionNet do
  @moduledoc """
  A small fake web for FEP-f799 tests: a map from URL to what the server
  answers, handed to `Fetch` / `Control` as `http:`. Every request is also
  sent to the test process as `{:requested, url, headers}`.
  """

  @activity "application/activity+json"

  @doc "The `http:` function for `web`: `%{url => response | [response, …] | fun}`."
  def http(web) do
    parent = self()

    fn url, headers ->
      send(parent, {:requested, url, headers})

      case Map.get(web, url) do
        nil -> {:ok, %{status: 404, headers: %{}, body: ""}}
        fun when is_function(fun, 1) -> fun.(headers)
        response -> response
      end
    end
  end

  def json(document, opts \\ []) do
    {:ok,
     %{
       status: Keyword.get(opts, :status, 200),
       headers: %{"content-type" => [Keyword.get(opts, :type, @activity)]},
       body: JSON.encode!(document)
     }}
  end

  def status(code, headers \\ %{}), do: {:ok, %{status: code, headers: headers, body: ""}}
  def redirect(to), do: status(302, %{"location" => [to]})
  def down, do: {:error, %Req.TransportError{reason: :timeout}}
end
