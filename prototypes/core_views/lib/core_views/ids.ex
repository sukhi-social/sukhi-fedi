# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule CoreViews.Ids do
  @moduledoc """
  The IDs of a record (`sukhi_id_s1_section_draft.md`).

    * `ap/uuid`: a UUIDv7, the primary ID. hosigraph's integer `:id` stays inside.
    * `ap/id`: the API ID. Local: `s1k..`, the UUID in readable form (35 characters, reversible).
      Remote: `s0kza..`, a hash of the object's URI.
    * `ap/short-id`: local only, the first 24 characters of `ap/id`.
  """
  import Ecto.Changeset

  @alphabet ~c"0123456789abcdefghjkmnpqrstvwxyz"
  @digits Map.new(Enum.with_index(@alphabet))
  @day_ms 86_400_000
  @short 24

  @doc "The `s1` ID of a UUIDv7. `code` is the category: `\"on\"`, `\"xa\"`, `\"xl\"`, `\"xf\"`."
  def s1(<<_::128>> = bin, <<_::binary-2>> = code) do
    <<ms::48, 7::4, rand_a::12, 2::2, rand_b::62>> = bin
    at = DateTime.from_unix!(ms, :millisecond)
    date = at |> DateTime.to_date() |> Date.to_iso8601(:basic)
    <<rand::74>> = <<rand_a::12, rand_b::62>>
    "s1k" <> code <> date <> "t" <> base32(rem(ms, @day_ms), 6) <> base32(rand, 15)
  end

  def s1(uuid, code) do
    {:ok, bin} = Ecto.UUID.dump(uuid)
    s1(bin, code)
  end

  @doc "`{:ok, %{uuid:, code:, unix_ms:}}` from a canonical `s1` ID."
  def decode_s1(
        <<"s1k", code::binary-2, y::binary-4, m::binary-2, d::binary-2, "t", ms::binary-6,
          rand::binary-15>>
      ) do
    with {:ok, date} <- Date.from_iso8601("#{y}-#{m}-#{d}"),
         {:ok, ms} when ms < @day_ms <- number(ms),
         {:ok, rand} when rand < 0x4000000000000000000 <- number(rand) do
      unix_ms = Date.diff(date, ~D[1970-01-01]) * @day_ms + ms
      <<rand_a::12, rand_b::62>> = <<rand::74>>
      {:ok, uuid} = Ecto.UUID.load(<<unix_ms::48, 7::4, rand_a::12, 2::2, rand_b::62>>)
      {:ok, %{uuid: uuid, code: code, unix_ms: unix_ms}}
    else
      _ -> :error
    end
  end

  def decode_s1(_), do: :error

  @doc """
  The `s0kza` ID of a remote URI: 128 bits of its SHA-256. The draft leaves open on which side the
  26 characters are padded; here the number is padded on the left.
  """
  def s0kza(uri) when is_binary(uri) do
    <<hash::128, _::binary>> = :crypto.hash(:sha256, uri)
    "s0kza" <> base32(hash, 26)
  end

  @doc "A queried ID as it is searched (draft section 2.6). Only `s1k` and `s0kza` are changed."
  def normalize(id) when is_binary(id) do
    case String.downcase(id) do
      "s0kza" <> _ = lower ->
        lower

      "s1" <> _ = lower ->
        <<head::binary-size(5), rest::binary>> = pad_head(String.replace(lower, "-", ""))
        rest = String.replace(rest, ["o", "i", "l"], fn c -> if c == "o", do: "0", else: "1" end)

        case head <> rest do
          <<date::binary-13, "t", _::binary>> = ok when byte_size(date) == 13 -> ok
          <<date::binary-13, tail::binary>> -> date <> "t" <> tail
          other -> other
        end

      _ ->
        id
    end
  end

  # shorter than the head: nothing can match it
  defp pad_head(id) when byte_size(id) < 5, do: String.pad_trailing(id, 5, "?")
  defp pad_head(id), do: id

  @doc "The length of a short ID."
  def short_length, do: @short

  @doc """
  Give a new record its IDs. `uri` is the remote object's URI, or nil for a local record. A UUID
  that is already set is kept.
  """
  def put_ids(%{data: %{id: nil}} = changeset, code, uri) do
    case get_field(changeset, :uuid) || Ecto.UUID.generate(version: 7) do
      <<_::binary-14, "7", _::binary>> = uuid -> put_ids(changeset, code, uri, uuid)
      _ -> add_error(changeset, :uuid, "is not a UUIDv7")
    end
  end

  def put_ids(changeset, _code, _uri), do: changeset

  @doc "`put_ids/3` for an activity, which says with `:remote` that it came from another server."
  def put_ids_of_activity(changeset, code) do
    if get_field(changeset, :remote) do
      changeset = validate_required(changeset, [:ap_id])
      put_ids(changeset, code, get_field(changeset, :ap_id))
    else
      put_ids(changeset, code, nil)
    end
    |> unique_constraint(:ap_id, name: name(changeset, "uri"))
  end

  defp put_ids(changeset, code, uri, uuid) do
    api_id = if uri, do: s0kza(uri), else: s1(uuid, code)
    short = if uri, do: nil, else: binary_part(api_id, 0, @short)

    changeset
    |> change(uuid: uuid, api_id: api_id, short_id: short)
    |> unique_constraint(:uuid, name: name(changeset, "uuid"))
    |> unique_constraint(:api_id, name: name(changeset, "id"))
    |> unique_constraint(:short_id, name: name(changeset, "short-id"))
  end

  defp name(changeset, attr), do: "#{changeset.data.__meta__.source}_ap/#{attr}_index"

  defp base32(n, length) do
    for shift <- (length - 1)..0//-1, into: "" do
      <<Enum.at(@alphabet, Bitwise.band(Bitwise.bsr(n, shift * 5), 31))>>
    end
  end

  defp number(text) do
    text
    |> String.to_charlist()
    |> Enum.reduce_while({:ok, 0}, fn c, {:ok, n} ->
      case @digits do
        %{^c => d} -> {:cont, {:ok, n * 32 + d}}
        _ -> {:halt, :error}
      end
    end)
  end
end
