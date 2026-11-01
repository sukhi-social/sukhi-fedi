# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Web.NodeinfoController do
  @moduledoc """
  NodeInfo discovery and document endpoints.

  Spec: https://github.com/jhass/nodeinfo

    GET /.well-known/nodeinfo  → discovery JSON with links
    GET /nodeinfo/2.1          → actual NodeInfo 2.1 document

  Pure Elixir — no NATS round-trip. Counts are best-effort Ecto queries;
  they fall back to 0 if the query fails so the endpoint never 500s.
  """

  import Plug.Conn
  import Ecto.Query

  alias SukhiFedi.Repo
  alias SukhiFedi.Schema.{Account, Note}

  def discovery(conn, _opts) do
    domain = SukhiFedi.Config.domain!()

    body = %{
      links: [
        %{
          rel: "http://nodeinfo.diaspora.software/ns/schema/2.0",
          href: "https://#{domain}/nodeinfo/2.0"
        },
        %{
          rel: "http://nodeinfo.diaspora.software/ns/schema/2.1",
          href: "https://#{domain}/nodeinfo/2.1"
        }
      ]
    }

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, JSON.encode!(body))
  end

  # mix.exs の :sukhi_fedi バージョンを単一の出どころにする。
  # Mastodon `/api/v1/instance` の `version` 文字列も同じ VERSION ファイル
  # を読むので、nodeinfo と instance が必ず一致する。
  # 起動時(:sukhi_fedi が load 済み)の Application.spec から取るので
  # release 再ビルド不要で値が更新される。
  def software_version do
    case Application.spec(:sukhi_fedi, :vsn) do
      nil -> "0.0.0"
      vsn -> to_string(vsn)
    end
  end

  def v2_0(conn, _opts), do: send_document(conn, "2.0")
  def v2_1(conn, _opts), do: send_document(conn, "2.1")

  # NodeInfo 2.0 and 2.1 share these fields; 2.1's extra software keys
  # (repository/homepage) are optional, so one body serves both.
  defp send_document(conn, version) do
    body = %{
      version: version,
      software: %{
        name: "sukhi-fedi",
        version: software_version()
      },
      protocols: ["activitypub"],
      services: %{
        inbound: [],
        outbound: []
      },
      usage: %{
        users: %{
          total: count_safe(from a in Account, where: is_nil(a.domain)),
          activeMonth: 0,
          activeHalfyear: 0
        },
        localPosts: count_safe(from n in Note, where: is_nil(n.domain))
      },
      # 招待制サーバ。完全 open になる日が来たら
      # `SukhiFedi.Config` か runtime env でひっくり返せるようにする。
      openRegistrations: false,
      # Misskey 系・各種ディレクトリが拾う、サイトの名前とロゴ。
      metadata: %{
        nodeName: SukhiFedi.Config.title(),
        iconUrl: SukhiFedi.Config.logo_url()
      }
    }

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, JSON.encode!(body))
  end

  defp count_safe(queryable) do
    Repo.aggregate(queryable, :count, :id)
  rescue
    _ -> 0
  end
end
