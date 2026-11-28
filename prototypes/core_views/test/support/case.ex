# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule CoreViews.Case do
  @moduledoc "A Repo on an empty store for each test."
  use ExUnit.CaseTemplate

  alias CoreViews.{Boost, Follow, Note, Reaction, Repo}

  using do
    quote do
      import CoreViews.Case
      import Ecto.Query
      alias CoreViews.{Boost, Follow, Note, Reaction, Repo, Timelines, Tombstone}
    end
  end

  setup do
    dir = Path.join(System.tmp_dir!(), "core_views_#{System.os_time()}")
    File.rm_rf!(dir)

    backend =
      case System.get_env("HOSI_REAL") do
        nil ->
          [hosi: Ecto.Hosi.Fake]

        _ ->
          java = System.get_env("HOSI_JAVA", "java")
          [khana: [jvm: System.fetch_env!("HOSI_JAR"), java: java]]
      end

    start_supervised!({Repo, [dir: dir, schemas: Repo.views()] ++ backend}, restart: :temporary)

    on_exit(fn -> File.rm_rf!(dir) end)
    :ok
  end

  def note!(account_id, attrs \\ %{}) do
    attrs = Map.merge(%{account_id: account_id, content: "hello"}, Map.new(attrs))
    insert!(%Note{}, &Note.changeset/2, attrs)
  end

  def boost!(account_id, note, attrs \\ %{}) do
    attrs = Map.merge(%{account_id: account_id, note_id: note.id}, Map.new(attrs))
    insert!(%Boost{}, &Boost.changeset/2, attrs)
  end

  def react(account_id, note, emoji) do
    attrs = %{account_id: account_id, note_id: note.id, emoji: emoji}
    insert(%Reaction{}, &Reaction.changeset/2, attrs)
  end

  def follow!(follower_id, followee_id, state \\ "accepted") do
    insert!(%Follow{}, &Follow.changeset/2, %{
      follower_id: follower_id,
      follower_uri: uri(follower_id),
      followee_id: followee_id,
      state: state
    })
  end

  def insert(struct, changeset, attrs) do
    CoreViews.Records.insert(fn
      nil -> changeset.(struct, attrs)
      uuid -> changeset.(struct, Map.put(attrs, :uuid, uuid))
    end)
  end

  def insert!(struct, changeset, attrs) do
    {:ok, record} = insert(struct, changeset, attrs)
    record
  end

  def uri(account_id), do: "https://here.test/users/#{account_id}"
end
