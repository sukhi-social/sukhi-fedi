# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiShared.DeliverySuspension.Hint do
  @moduledoc """
  A server that is resting can say so in the answer to a delivery:

      Link: <https://rest.example/suspensions/1>; rel="https://w3id.org/fep/f799#deliverySuspension"

  That is a **hint, not an authority**. All it does is tell us where to look;
  what is found there is judged like any notice (`Receiver`, control and all),
  and an unconfirmed notice suspends nothing.

  This reads the hint out of a response's headers and nothing else: the first
  link with that rel, resolved against the URL that was asked, as an `https`
  URL of a kind we would deliver to (`Origin.of_delivery_url/1`), at most
  2048 bytes. Anything else is no hint. It lives in `shared` because the
  delivery node reads responses and the gateway node fetches notices.
  """

  alias SukhiShared.DeliverySuspension.Origin

  # Draft name, in one place.
  @rel "https://w3id.org/fep/f799#deliverySuspension"
  @rel_controller "https://w3id.org/fep/f799#deliveryController"
  @max_url_bytes 2048

  @doc "The relation that names a resting notice."
  @spec rel() :: String.t()
  def rel, do: @rel

  @doc "The WebFinger relation that names an origin's delivery controller."
  @spec rel_controller() :: String.t()
  def rel_controller, do: @rel_controller

  @doc """
  The notice URL a response points to, or `:none`. `headers` is a map of
  lists (Req) or a list of pairs; `asked` is the URL the request went to.
  """
  @spec notice_url(map() | [{term(), term()}] | term(), String.t()) :: {:ok, String.t()} | :none
  def notice_url(headers, asked) when is_binary(asked) do
    headers
    |> link_values()
    |> Enum.find_value(:none, fn value ->
      case first_with_rel(value, asked) do
        {:ok, _} = found -> found
        :none -> nil
      end
    end)
  end

  def notice_url(_headers, _asked), do: :none

  # Every `Link` header value, in order.
  defp link_values(headers) when is_map(headers) do
    headers
    |> Enum.filter(fn {name, _} -> String.downcase(to_string(name)) == "link" end)
    |> Enum.flat_map(fn {_, value} -> List.wrap(value) end)
    |> Enum.filter(&is_binary/1)
  end

  defp link_values(headers) when is_list(headers) do
    for {name, value} <- headers,
        String.downcase(to_string(name)) == "link",
        is_binary(value),
        do: value
  end

  defp link_values(_headers), do: []

  # `<target>` followed by its parameters, up to the next `<`. Commas between
  # links ride along in the parameters and are never part of `rel=`.
  defp first_with_rel(value, asked) do
    ~r/<([^>]*)>([^<]*)/
    |> Regex.scan(value)
    |> Enum.find_value(:none, fn [_, target, params] ->
      with true <- has_rel?(params),
           {:ok, url} <- resolve(target, asked) do
        {:ok, url}
      else
        _ -> nil
      end
    end)
  end

  defp has_rel?(params) do
    case Regex.run(~r/;\s*rel\s*=\s*(?:"([^"]*)"|([^\s;,"]+))/i, params) do
      # a quoted value is a space-separated list of relations; a bare one is one
      [_, "", bare] -> bare == @rel
      [_, quoted] -> @rel in String.split(quoted)
      _ -> false
    end
  end

  defp resolve(target, asked) do
    target = String.trim(target)

    with true <- target != "" and byte_size(target) <= @max_url_bytes,
         %URI{} = uri <- URI.merge(asked, target),
         url = URI.to_string(%{uri | fragment: nil}),
         true <- byte_size(url) <= @max_url_bytes,
         %URI{scheme: "https"} <- URI.parse(url),
         {:ok, _origin} <- Origin.of_delivery_url(url) do
      {:ok, url}
    else
      _ -> :error
    end
  rescue
    _ -> :error
  end
end
