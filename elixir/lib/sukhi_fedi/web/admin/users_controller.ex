# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Web.Admin.UsersController do
  @moduledoc """
  `/admin/users` — list local accounts, search, suspend/unsuspend.

  Suspend/unsuspend hit `SukhiFedi.Addons.Moderation` and return only
  the row fragment for htmx swap-target.
  """

  import Ecto.Query
  import Plug.Conn

  alias SukhiFedi.Addons.Moderation
  alias SukhiFedi.Repo
  alias SukhiFedi.Schema.Account
  alias SukhiFedi.Web.Admin.Render

  @page_size 50

  def index(conn) do
    q = (conn.params["q"] || "") |> String.trim()
    page = parse_page(conn.params["page"])

    base =
      from a in Account,
        where: is_nil(a.domain),
        order_by: [asc: a.username]

    base =
      if q == "" do
        base
      else
        like = "%" <> q <> "%"
        from a in base, where: ilike(a.username, ^like) or ilike(a.display_name, ^like)
      end

    users =
      base
      |> limit(@page_size)
      |> offset(^((page - 1) * @page_size))
      |> Repo.all()

    Render.send_page(conn, "users/index.html.eex",
      page_title: "Users",
      users: users,
      q: q,
      page: page,
      has_next: length(users) == @page_size
    )
  end

  def suspend(conn, id) do
    with {:ok, account} <- find_local(id),
         admin_id = conn.assigns.admin.id,
         {:ok, updated} <-
           Moderation.suspend_account(account.id, admin_id, conn.body_params["reason"] || "") do
      Render.send_fragment(conn, "users/_row.html.eex", user: updated)
    else
      _ -> send_resp(conn, 404, "")
    end
  end

  def unsuspend(conn, id) do
    with {:ok, account} <- find_local(id),
         admin_id = conn.assigns.admin.id,
         {:ok, updated} <- Moderation.unsuspend_account(account.id, admin_id) do
      Render.send_fragment(conn, "users/_row.html.eex", user: updated)
    else
      _ -> send_resp(conn, 404, "")
    end
  end

  # One text box, names separated by commas — the common case. Colors
  # stay whatever each badge already wears (a name kept keeps its color);
  # the API takes the full shape.
  def roles(conn, id) do
    with {:ok, account} <- find_local(id) do
      current = Map.new(account.roles, &{SukhiFedi.HTML.unescape(&1["name"]), &1["color"]})

      rows =
        (conn.body_params["roles"] || "")
        |> String.split(",", trim: true)
        |> Enum.map(&String.trim/1)
        |> Enum.map(&%{"name" => &1, "color" => Map.get(current, &1, "")})

      case SukhiFedi.Accounts.set_roles(account.id, conn.assigns.admin.id, rows) do
        {:ok, updated} -> Render.send_fragment(conn, "users/_row.html.eex", user: updated)
        _ -> send_resp(conn, 404, "")
      end
    else
      _ -> send_resp(conn, 404, "")
    end
  end

  defp find_local(id) do
    case Integer.parse(to_string(id)) do
      {n, ""} ->
        case Repo.get(Account, n) do
          %Account{domain: nil} = a -> {:ok, a}
          _ -> :error
        end

      _ ->
        :error
    end
  end

  defp parse_page(nil), do: 1

  defp parse_page(s) do
    case Integer.parse(to_string(s)) do
      {n, ""} when n > 0 -> n
      _ -> 1
    end
  end
end
