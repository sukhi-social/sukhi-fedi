# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Notes.Ids do
  @moduledoc """
  Note ids and AP URLs, both directions.

  The one convention everything here leans on: a local note carries no
  `ap_id` — its public AP URL (`https://<domain>/users/<u>/notes/<id>`)
  is synthesized on demand, the same way the delivery node and AP
  controllers publish it. A remote note always stores its real `ap_id`.
  """

  import Ecto.Query

  alias SukhiFedi.{Accounts, Repo}
  alias SukhiFedi.Schema.{Account, Note}

  @doc "Parse a note id from an integer or numeric string; nil otherwise."
  @spec parse_int(term()) :: integer() | nil
  def parse_int(n) when is_integer(n), do: n

  def parse_int(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} -> n
      _ -> nil
    end
  end

  def parse_int(_), do: nil

  @doc """
  A note's public AP id, looked up by numeric id: the stored `ap_id`
  for remote notes, or the synthesized URL for local ones. Nil when
  the note doesn't exist.
  """
  @spec note_ap_id(integer()) :: String.t() | nil
  def note_ap_id(note_id) do
    case Repo.one(from(n in Note, where: n.id == ^note_id, select: {n.ap_id, n.account_id})) do
      {ap_id, _account_id} when is_binary(ap_id) ->
        ap_id

      {nil, account_id} ->
        local_author_note_url(Accounts.get(account_id), note_id)

      nil ->
        nil
    end
  end

  defp local_author_note_url(%Account{domain: nil, username: username}, note_id),
    do: "https://#{SukhiFedi.Config.domain!()}/users/#{username}/notes/#{note_id}"

  defp local_author_note_url(_, _), do: nil

  # A note's public AP id from the struct: the stored `ap_id` for remote
  # notes, or the synthesized `/notes/<id>` URL for local ones (whose
  # `ap_id` is NULL). Needs `:account` preloaded; nil if neither applies.
  @spec local_note_ap_id(Note.t() | term()) :: String.t() | nil
  def local_note_ap_id(%Note{ap_id: ap_id}) when is_binary(ap_id), do: ap_id

  def local_note_ap_id(%Note{ap_id: nil, id: id, account: %Account{username: u, domain: nil}}),
    do: "https://#{SukhiFedi.Config.domain!()}/users/#{u}/notes/#{id}"

  def local_note_ap_id(_), do: nil

  # The numeric id from one of our own synthesized note URLs; nil otherwise.
  @spec local_note_id_from_uri(term()) :: integer() | nil
  def local_note_id_from_uri(uri) when is_binary(uri) do
    domain = SukhiFedi.Config.domain!()

    case Regex.run(~r{^https?://#{Regex.escape(domain)}/users/[^/]+/notes/(\d+)$}, uri) do
      [_, id] -> String.to_integer(id)
      _ -> nil
    end
  end

  def local_note_id_from_uri(_), do: nil
end
