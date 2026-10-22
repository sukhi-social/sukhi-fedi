# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Web.Admin.Render do
  @moduledoc """
  EEx template rendering for the `/admin` web UI.

  Templates live in `priv/admin_templates/` and are evaluated at request
  time. Admin is low-traffic — precompilation would be premature.

  Use `send_page/3` for full HTML responses (wraps the template in
  `_layout.html.eex`), `send_fragment/3` for htmx partial swaps
  (template only, no layout).
  """

  import Plug.Conn

  # Prepended to every template body before EEx evaluation so the `h/1`
  # helper is in scope without templates having to write the full name.
  @helpers_prelude "<% import SukhiFedi.Web.Admin.Render, only: [h: 1, ago: 1, span: 1] %>"

  @doc "HTML-escape a value for safe interpolation in templates."
  def h(nil), do: ""

  def h(value) do
    value
    |> to_string()
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&#39;")
  end

  @doc """
  "3秒前" / "12分前" / "2時間前" for a past instant (relative to now); "—" for nil.
  """
  def ago(nil), do: "—"
  def ago(%NaiveDateTime{} = at), do: at |> DateTime.from_naive!("Etc/UTC") |> ago()
  def ago(%DateTime{} = at), do: DateTime.diff(DateTime.utc_now(), at, :second) |> ago()

  def ago(s) when is_integer(s) do
    s = max(s, 0)

    cond do
      s < 5 -> "いま"
      s < 60 -> "#{s}秒前"
      s < 3600 -> "#{div(s, 60)}分前"
      s < 86_400 -> "#{div(s, 3600)}時間前"
      true -> "#{div(s, 86_400)}日前"
    end
  end

  @doc "Length of a duration in seconds, as \"45秒\" / \"12分\" / \"2時間30分\"."
  def span(s) when is_integer(s) do
    s = max(s, 0)

    cond do
      s < 60 -> "#{s}秒"
      s < 3600 -> "#{div(s, 60)}分"
      true -> "#{div(s, 3600)}時間#{div(rem(s, 3600), 60)}分"
    end
  end

  @doc "Render a template wrapped in the admin layout."
  def send_page(conn, template, assigns \\ []) do
    content = render_template(template, assigns)

    layout_bindings = [
      inner: content,
      page_title: assigns[:page_title] || "Admin",
      admin: conn.assigns[:admin],
      current_path: conn.request_path,
      flash: get_session(conn, :flash) || %{}
    ]

    html = render_template("_layout.html.eex", layout_bindings)

    conn
    |> delete_session(:flash)
    |> put_resp_content_type("text/html; charset=utf-8")
    |> send_resp(200, html)
  end

  @doc "Render a template without layout (for htmx partial swaps)."
  def send_fragment(conn, template, assigns \\ []) do
    html = render_template(template, assigns)

    conn
    |> put_resp_content_type("text/html; charset=utf-8")
    |> send_resp(200, html)
  end

  @doc "Set a one-shot flash message read by the next page render."
  def put_flash(conn, level, message) when level in [:info, :error] do
    put_session(conn, :flash, %{level: level, message: message})
  end

  @doc """
  Render a template by file path. Bindings is a keyword list whose
  keys become bound variables in the template. `h/1` is auto-imported
  so templates can write `<%= h(user.username) %>`.
  """
  def render_template(template, bindings) do
    path = Path.join([:code.priv_dir(:sukhi_fedi), "admin_templates", template])
    body = File.read!(path)
    EEx.eval_string(@helpers_prelude <> body, bindings, file: path)
  end
end
