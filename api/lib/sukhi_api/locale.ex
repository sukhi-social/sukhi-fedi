# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiApi.Locale do
  @moduledoc """
  Pick a UI locale for a request, mirroring the web client's rule in
  `web/src/lib/i18n.ts`: Korean when the reader asks for Korean,
  Japanese otherwise. The web client reads its own `localStorage`
  first; a server has only the request, so we read `Accept-Language`.

  Supported locales match the web client exactly: `:ja` (the default)
  and `:ko`. Any server-authored, reader-facing copy (the ご近所 guide
  post, the official list title) routes through here so it speaks the
  same two languages the UI does.
  """

  @type t :: :ja | :ko

  @doc "The locale for this request (`:ja` default, `:ko` for Korean)."
  @spec from_req(map()) :: t()
  def from_req(req) do
    (req[:headers] || [])
    |> accept_language()
    |> from_accept_language()
  end

  @doc "Same rule applied to a raw `Accept-Language` value."
  @spec from_accept_language(String.t()) :: t()
  def from_accept_language(value) do
    primary =
      value
      |> String.split(",", parts: 2)
      |> List.first()
      |> to_string()
      |> String.trim()
      |> String.downcase()

    if String.starts_with?(primary, "ko"), do: :ko, else: :ja
  end

  defp accept_language(headers) do
    Enum.find_value(headers, "", fn {k, v} ->
      if String.downcase(to_string(k)) == "accept-language", do: to_string(v), else: nil
    end)
  end
end
