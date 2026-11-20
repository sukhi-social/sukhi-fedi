# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiHosi.Actors do
  @moduledoc "People, ours and remote. An actor is found by its IRI; a handle is only a name."

  alias SukhiHosi.Store

  @base "https://local.test/users/"
  @local_host URI.parse(@base).host

  def create_local(db, handle) do
    ops = [
      [:create, [:tmp, 1], :"actor/id", @base <> handle],
      [:create, [:tmp, 1], :"actor/username", handle],
      [:create, [:tmp, 1], :"actor/local?", true]
    ]

    {:ok, %{temps: [[1, id]]}} = Hosi.write(db, ops)
    id
  end

  def find(db, iri), do: Store.lookup(db, :"actor/id", iri)
  def find_local(db, handle), do: find(db, @base <> handle)

  @doc """
  The actor a handle names: `@name` is one of ours, `@name@host` is the one of that host (and ours,
  when the host is ours). A handle is only a name; it is looked at the way it was written, then in
  lower case. nil when we do not know them.
  """
  def find_handle(db, name, host \\ nil) do
    names = Enum.uniq([name, String.downcase(name)])

    if host == nil or String.downcase(host) == @local_host do
      Enum.find_value(names, &find_local(db, &1))
    else
      host = String.downcase(host)

      Enum.find_value(names, fn n ->
        case Store.rows(db, "[:find ?e :in $ ?u ?h :where [?e :actor/username ?u] [?e :actor/host ?h]]", [[:scalar, n], [:scalar, host]]) do
          [] -> nil
          rows -> rows |> List.flatten() |> Enum.min()
        end
      end)
    end
  end

  def iri(db, id) do
    [e] = Store.entities(db, [id])
    e |> Map.get(:"actor/id", []) |> List.first()
  end

  @doc "Ops that make a remote actor, as `[:tmp, n]`, for a write that needs it at once."
  def remote_ops(n, iri) do
    uri = URI.parse(iri)

    [
      [:create, [:tmp, n], :"actor/id", iri],
      [:create, [:tmp, n], :"actor/username", Path.basename(uri.path || "")],
      [:create, [:tmp, n], :"actor/host", uri.host],
      [:create, [:tmp, n], :"actor/local?", false]
    ]
  end
end
