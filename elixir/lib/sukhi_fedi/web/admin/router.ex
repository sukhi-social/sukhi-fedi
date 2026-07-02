# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Web.Admin.Router do
  @moduledoc """
  Routes for the `/admin` web UI.

  Forwarded from the main router via `forward "/admin", to: ...`. The
  forward strips the `/admin` prefix, so paths here are relative to
  `/admin` (i.e. `get "/users"` matches `GET /admin/users`).

  Authenticated routes use `Auth.with_admin/2`; unauthenticated routes
  (login form, login submit) are explicit and self-contained.
  """

  use Plug.Router

  alias SukhiFedi.Web.Admin.{AnnouncementsController, Auth, BubbleInstancesController,
                              DashboardController, InstanceBlocksController,
                              InviteCodesController, LoginController, MapPeersController,
                              ReportsController, SystemController, UsersController}

  plug :put_secret_key_base

  # `secure: true` so the session cookie never leaks over plain HTTP in
  # production. Dev/test override via `config :sukhi_fedi, :admin_session_secure`.
  @session_opts [
    store: :cookie,
    key: "_sukhi_admin_session",
    signing_salt: "sukhi-admin-v1",
    same_site: "Lax",
    http_only: true,
    secure: Application.compile_env(:sukhi_fedi, :admin_session_secure, true),
    max_age: 60 * 60 * 24 * 14
  ]

  plug Plug.Session, @session_opts

  plug :fetch_session
  plug :match

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart],
    pass: ["*/*"]

  plug :dispatch

  # ── Unauthenticated ─────────────────────────────────────────────────────

  get "/login" do
    LoginController.show(conn)
  end

  post "/login" do
    LoginController.submit(conn)
  end

  post "/logout" do
    LoginController.logout(conn)
  end

  # ── Authenticated ──────────────────────────────────────────────────────

  get "/" do
    Auth.with_admin(conn, &DashboardController.index/1)
  end

  get "/users" do
    Auth.with_admin(conn, &UsersController.index/1)
  end

  post "/users/:id/suspend" do
    Auth.with_admin(conn, &UsersController.suspend(&1, id))
  end

  post "/users/:id/unsuspend" do
    Auth.with_admin(conn, &UsersController.unsuspend(&1, id))
  end

  get "/reports" do
    Auth.with_admin(conn, &ReportsController.index/1)
  end

  post "/reports/:id/resolve" do
    Auth.with_admin(conn, &ReportsController.resolve(&1, id))
  end

  get "/invite_codes" do
    Auth.with_admin(conn, &InviteCodesController.index/1)
  end

  post "/invite_codes" do
    Auth.with_admin(conn, &InviteCodesController.create/1)
  end

  get "/announcements" do
    Auth.with_admin(conn, &AnnouncementsController.index/1)
  end

  post "/announcements" do
    Auth.with_admin(conn, &AnnouncementsController.create/1)
  end

  post "/announcements/:id/publish" do
    Auth.with_admin(conn, &AnnouncementsController.publish(&1, id))
  end

  post "/announcements/:id/unpublish" do
    Auth.with_admin(conn, &AnnouncementsController.unpublish(&1, id))
  end

  post "/announcements/:id/edit" do
    Auth.with_admin(conn, &AnnouncementsController.edit(&1, id))
  end

  post "/announcements/:id/delete" do
    Auth.with_admin(conn, &AnnouncementsController.delete(&1, id))
  end

  get "/system" do
    Auth.with_admin(conn, &SystemController.index/1)
  end

  get "/system/sample" do
    Auth.with_admin(conn, &SystemController.sample/1)
  end

  get "/instance_blocks" do
    Auth.with_admin(conn, &InstanceBlocksController.index/1)
  end

  post "/instance_blocks" do
    Auth.with_admin(conn, &InstanceBlocksController.create/1)
  end

  post "/instance_blocks/:domain/remove" do
    Auth.with_admin(conn, &InstanceBlocksController.remove(&1, domain))
  end

  get "/bubble_instances" do
    Auth.with_admin(conn, &BubbleInstancesController.index/1)
  end

  post "/bubble_instances" do
    Auth.with_admin(conn, &BubbleInstancesController.create/1)
  end

  post "/bubble_instances/:domain/remove" do
    Auth.with_admin(conn, &BubbleInstancesController.remove(&1, domain))
  end

  get "/map_peers" do
    Auth.with_admin(conn, &MapPeersController.index/1)
  end

  post "/map_peers" do
    Auth.with_admin(conn, &MapPeersController.create/1)
  end

  post "/map_peers/:domain/remove" do
    Auth.with_admin(conn, &MapPeersController.remove(&1, domain))
  end

  match _ do
    send_resp(conn, 404, "")
  end

  # Plug.Session reads secret_key_base from conn — runtime.exs sets it
  # under :sukhi_fedi config so it's the same value across deploys for a
  # given SECRET_KEY_BASE env.
  defp put_secret_key_base(conn, _opts) do
    %{conn | secret_key_base: Application.fetch_env!(:sukhi_fedi, :secret_key_base)}
  end
end
