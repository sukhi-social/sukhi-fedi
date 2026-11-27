# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Audit do
  @moduledoc """
  The audit row of a Multi that also writes outside the audit's own store.

  The row is written through the audit's repo, not by the repo running the
  transaction. It is append-only, so it cannot be taken back: make it the
  last step, after everything that could still fail.
  """

  alias Ecto.Multi
  alias SukhiFedi.Repo
  alias SukhiFedi.Schema.AdminAudit

  @spec add_multi(Multi.t(), (map() -> map())) :: Multi.t()
  def add_multi(multi, attrs_fn) when is_function(attrs_fn, 1) do
    Multi.run(multi, :audit, fn _repo, changes ->
      changes |> attrs_fn.() |> AdminAudit.changeset() |> Repo.insert()
    end)
  end
end
