# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Repo.Migrations.AddContentHtmlToNotes do
  use Ecto.Migration

  @moduledoc """
  The rendered body of a locally-written note.

  Until now a local note was stored as escaped plaintext and served as
  `"<p>" <> that <> "</p>"`. That has always dropped the author's line
  breaks — a bare `\\n` inside `<p>` collapses to a space in HTML — so
  every multi-line post here, and every copy of it that reached another
  server, arrived as one run-on paragraph. Nobody had noticed because
  BudouX wraps Japanese at phrase boundaries, which looks like the line
  breaks working.

  So: render once, at write time, and keep the result. `content` stays
  the source the author typed (that is what search and the keyword
  filters want to read, and what an edit should start from);
  `content_html` is what readers and remote servers get.

  NULL means "there is no rendered form" and every reader falls back to
  `content`: that covers remote notes, whose `content` is already the
  HTML their server sent, and local notes written before this migration,
  which keep behaving exactly as they do today. Nothing is rewritten —
  the old posts stay as they were served.
  """

  def change do
    alter table(:notes) do
      add :content_html, :text
    end
  end
end
