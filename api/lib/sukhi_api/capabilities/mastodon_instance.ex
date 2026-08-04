# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiApi.Capabilities.MastodonInstance do
  @moduledoc """
  `GET /api/v1/instance` — Mastodon-compatible instance metadata.

  This is the example / MVP capability. Pattern to add more:
  drop a new file in `capabilities/`, `use SukhiApi.Capability`,
  implement `routes/0`, done.
  """

  use SukhiApi.Capability, addon: :mastodon_api

  # Same VERSION file as :sukhi_fedi reads. Runtime lookup (not a
  # compile-time module attribute) because :sukhi_api isn't loaded
  # during its own compile, so the attribute would freeze in as nil.
  defp sukhi_version do
    case Application.spec(:sukhi_api, :vsn) do
      nil -> "0.0.0"
      vsn -> to_string(vsn)
    end
  end

  @impl true
  def routes do
    [
      {:get, "/api/v1/instance", &instance_v1/1},
      {:get, "/api/v2/instance", &instance_v2/1}
    ]
  end

  def instance_v1(_req) do
    domain = SukhiApi.Config.domain!()
    title = Application.get_env(:sukhi_api, :title, "sukhi-fedi")

    body = %{
      uri: domain,
      title: title,
      short_description: "ActivityPub server (sukhi-fedi)",
      description: "ActivityPub server (sukhi-fedi)",
      email: "",
      version: "4.0.0 (compatible; sukhi-fedi #{sukhi_version()})",
      # No streaming WebSocket yet, so don't advertise one — otherwise
      # clients (Elk, Phanpy) open it, get 404, and sit in a perpetual
      # "reconnecting" error instead of falling back to REST polling.
      urls: %{},
      languages: ["en", "ja"],
      registrations: true,
      approval_required: false,
      invites_enabled: true,
      stats: %{user_count: 0, status_count: 0, domain_count: 0},
      contact_account: nil,
      rules: []
    }

    json(200, body)
  end

  # Mastodon v4+ clients prefer /api/v2/instance — same data,
  # restructured into nested groups. Falling back from v2 to v1 works
  # but logs a 404 each app start, which is what Moshidon was doing.
  def instance_v2(_req) do
    domain = SukhiApi.Config.domain!()
    title = Application.get_env(:sukhi_api, :title, "sukhi-fedi")

    body = %{
      domain: domain,
      title: title,
      version: "4.0.0 (compatible; sukhi-fedi #{sukhi_version()})",
      source_url: "https://github.com/f3liz-casa/sukhi-fedi",
      description: "ActivityPub server (sukhi-fedi)",
      usage: %{users: %{active_month: 0}},
      thumbnail: %{url: "https://#{domain}/favicon.png"},
      languages: ["en", "ja"],
      configuration: %{
        # streaming intentionally omitted — see instance_v1/1.
        accounts: %{max_featured_tags: 10, max_pinned_statuses: 5},
        statuses: %{
          max_characters: 500,
          max_media_attachments: 4,
          characters_reserved_per_url: 23
        },
        media_attachments: %{
          supported_mime_types: ["image/jpeg", "image/png", "image/gif", "image/webp"],
          image_size_limit: 8 * 1024 * 1024,
          image_matrix_limit: 16_777_216,
          video_size_limit: 0,
          video_frame_rate_limit: 0,
          video_matrix_limit: 0
        },
        polls: %{
          max_options: 4,
          max_characters_per_option: 50,
          min_expiration: 300,
          max_expiration: 2_629_746
        },
        translation: %{enabled: false},
        # Mastodon 4.3's shape. A client needs this *before* it has a
        # subscription: `GET /push/subscription` 404s until there is one,
        # so asking there can't tell "push is off on this server" from
        # "you haven't subscribed yet". Without it the settings panel
        # offers a button that burns the browser's one permission prompt
        # and then finds there is no key to encrypt to.
        vapid: %{public_key: vapid_public_key()},
        # Ours, not Mastodon's: which notification types may ever wake
        # somebody. The server decides and the client reads — two
        # literals drift, and this drift is a phone buzzing for a
        # favourite.
        direct_types: direct_types()
      },
      registrations: %{
        enabled: true,
        approval_required: false,
        message: nil
      },
      contact: %{email: "", account: nil},
      rules: []
    }

    json(200, body)
  end

  # nil when no keypair is configured — which is how a client learns that
  # push is simply off here, and hides its own switch instead of offering
  # one that cannot work.
  defp vapid_public_key do
    case SukhiApi.GatewayRpc.call(SukhiFedi.Addons.WebPush, :server_key, []) do
      {:ok, key} when is_binary(key) and key != "" -> key
      _ -> nil
    end
  end

  defp direct_types do
    case SukhiApi.GatewayRpc.call(SukhiFedi.Addons.WebPush, :direct_types, []) do
      {:ok, list} when is_list(list) -> list
      _ -> []
    end
  end

  defp json(status, body) do
    {:ok,
     %{
       status: status,
       body: JSON.encode!(body),
       headers: [{"content-type", "application/json"}]
     }}
  end
end
