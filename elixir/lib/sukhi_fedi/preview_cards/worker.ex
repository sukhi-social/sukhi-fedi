# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.PreviewCards.Worker do
  @moduledoc """
  Background link-preview generation (FEP-8967). Runs on the gateway so it
  never blocks the post write — the note is already saved by the time this
  fetches its first link.
  """

  use Oban.Worker, queue: :preview, max_attempts: 3

  alias SukhiFedi.PreviewCards

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"note_id" => note_id, "url" => url}}) do
    PreviewCards.generate(note_id, url)
  end
end
