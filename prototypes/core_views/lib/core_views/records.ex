# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule CoreViews.Records do
  @moduledoc "Writing a record with its IDs, and finding one by an API ID."
  alias CoreViews.{Boost, Follow, Ids, Note, Reaction, Repo, Tombstone}

  @tries 3

  @doc """
  `Repo.insert/1` for a changeset of a new record. A local record whose short ID is taken gets a
  new UUIDv7 (draft section 2.5); `remake` builds the changeset again with it.
  """
  def insert(remake, uuid \\ nil, tries \\ @tries) when is_function(remake, 1) do
    case Repo.insert(remake.(uuid)) do
      {:error, %{errors: errors} = changeset} ->
        if tries > 1 and Keyword.has_key?(errors, :short_id),
          do: insert(remake, Ecto.UUID.generate(version: 7), tries - 1),
          else: {:error, changeset}

      ok ->
        ok
    end
  end

  @doc """
  The record an API ID names, through the view of its type (a deleted one as `Tombstone`), or nil.
  Takes a canonical ID, a short one or a longer start of a local ID, in the forms for people.
  """
  def resolve(queried) do
    id = Ids.normalize(queried)

    cond do
      String.starts_with?(id, "s0kza") ->
        by(:"ap/id", id)

      String.starts_with?(id, "s1k") and byte_size(id) == 35 ->
        by(:"ap/id", id)

      String.starts_with?(id, "s1k") and byte_size(id) in Ids.short_length()..34 ->
        with %{api_id: full} = record <-
               by(:"ap/short-id", binary_part(id, 0, Ids.short_length())),
             true <- String.starts_with?(full, id) do
          record
        else
          _ -> nil
        end

      true ->
        nil
    end
  end

  # one search whatever the kind: the names are shared
  defp by(attr, value) do
    q = %{
      q: "[:find ?e ?t :in $ ?v :where [?e :#{attr} ?v] [?e :ap/type ?t]]",
      inputs: [[:scalar, value]]
    }

    case Repo.datalog(q) do
      [[id, type]] -> Repo.get(view(to_string(type)), id)
      [] -> nil
    end
  end

  defp view("note"), do: Note
  defp view("announce"), do: Boost
  defp view("like"), do: Reaction
  defp view("follow"), do: Follow
  defp view("tombstone"), do: Tombstone
end
