# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiApi.Capabilities.SukhiBots do
  @moduledoc """
  手だけのアカウント(Sukhi extension; not in the Mastodon spec)。
  パスワードも、メールも、画面のログインも無く、鍵(token)一本だけで
  書く垢を admin が作る。ふたりで読んだ記録を板に残す手、橋の向こう
  から書く手、のような用途。

      POST /api/v1/sukhi/bots            {username, display_name}   write:accounts + admin
      POST /api/v1/sukhi/bots/:id/token                             write:accounts + admin

  一本目の返事にだけ鍵が載る。二本目は鍵の取り替えで、古い鍵は全部
  その場で閉じる。

  認可は `/api/admin/*` の admin scope ではなく「write scope + admin か」
  ── web も natadeco も token に admin scope を頼んでいないので、板を
  立てる口(`Deco`)と同じ流儀にしている。中身は gateway の
  `SukhiFedi.LocalAccounts.create_bot/2` と `rotate_bot_token/2`。
  """

  use SukhiApi.Capability, addon: :mastodon_api

  alias SukhiApi.{AdminAuth, GatewayRpc}
  alias SukhiApi.Views.MastodonAccount

  @gateway SukhiFedi.LocalAccounts

  @impl true
  def routes do
    [
      {:post, "/api/v1/sukhi/bots", &create/1, scope: "write:accounts"},
      {:post, "/api/v1/sukhi/bots/:id/token", &rotate_token/1, scope: "write:accounts"}
    ]
  end

  def create(req) do
    with {:ok, admin} <- AdminAuth.require_admin(req) do
      body = decode_body(req)
      attrs = Map.take(body, ["username", "display_name"])
      call(:create_bot, [admin.id, attrs], &ok(201, render(&1)))
    else
      {:error, :forbidden} -> ok(403, %{error: "admin_required"})
    end
  end

  def rotate_token(req) do
    with {:ok, admin} <- AdminAuth.require_admin(req),
         {id, ""} <- Integer.parse(req[:path_params]["id"] || "") do
      call(:rotate_bot_token, [admin.id, id], &ok(200, render(&1)))
    else
      {:error, :forbidden} -> ok(403, %{error: "admin_required"})
      _ -> ok(400, %{error: "invalid_id"})
    end
  end

  defp render(%{account: account, token: token}),
    do: %{account: MastodonAccount.render(account), token: token}

  # 中身は JSON でしか来ない口(SPA と curl)。form は受けない。
  defp decode_body(req) do
    case JSON.decode(req[:body] || "") do
      {:ok, %{} = m} -> m
      _ -> %{}
    end
  end

  defp ok(status, body) do
    {:ok,
     %{
       status: status,
       body: JSON.encode!(body),
       headers: [{"content-type", "application/json"}]
     }}
  end

  defp call(fun, args, on_ok) do
    case GatewayRpc.call(@gateway, fun, args) do
      {:ok, {:ok, value}} ->
        on_ok.(value)

      {:ok, {:error, :not_found}} ->
        ok(404, %{error: "not_found"})

      {:ok, {:error, {:validation, errors}}} ->
        ok(422, %{error: "validation", detail: errors})

      {:ok, {:error, reason}} ->
        ok(422, %{error: to_string(reason)})

      {:error, :not_connected} ->
        ok(503, %{error: "gateway_not_connected"})

      {:error, {:badrpc, reason}} ->
        ok(503, %{error: "gateway_rpc_failed", detail: inspect(reason)})

      _ ->
        ok(500, %{error: "internal_error"})
    end
  end
end
