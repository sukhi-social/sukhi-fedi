# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule CoreViews.ActivityPub do
  @moduledoc """
  The shared `ap/` attributes the core records use. A rule here holds for every record that has
  the attribute, whichever view wrote it.

  `ap/actor`, `ap/object` and `ap/content` are ActivityStreams names that the hosigraph plan's
  table (section 2.4) does not list yet.
  """
  use Ecto.Hosi.Vocabulary, prefix: "ap"

  @types ["note", "announce", "like", "follow", "tombstone"]

  attribute(:type, :keyword, values: @types, record_type: true)
  attribute(:former_type, :keyword, values: @types -- ["tombstone"])
  attribute(:uri, :string, unique: true, final: true)
  # the primary ID, the API ID and the short API ID (`CoreViews.Ids`)
  attribute(:uuid, Ecto.UUID, unique: true, final: true)
  attribute(:id, :string, unique: true, final: true)
  attribute(:short_id, :string, unique: true, final: true)
  # accounts are in PostgreSQL: these two name records that hosigraph does not hold
  attribute(:attributed_to, :ref, on_delete: :keep, final: true)
  attribute(:actor, :ref, on_delete: :keep, final: true)
  # what an activity is about: it goes when that goes
  attribute(:object, :ref, on_delete: :cascade, final: true)
  attribute(:content, :string)
  attribute(:tag, :string, many: true)
  attribute(:attachment, :ref, many: true, on_delete: :nilify)
  attribute(:registered_at, :utc_datetime)
  attribute(:deleted, :utc_datetime_usec)
end
