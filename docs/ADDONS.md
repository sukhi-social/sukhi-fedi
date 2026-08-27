# sukhi-fedi addons

> Addons are the "polymorphic gem" unit. Core + a chosen set of addons
> = an instance. Operators pick which ones to run via `ENABLED_ADDONS`
> in `.env`; Watchtower ships new code; migrations re-run on restart.

## ABI contract (v1)

A sukhi-fedi **addon** declares itself with `use SukhiFedi.Addon, id:
:some_id` (gateway) and an object exported from `bun/addons/<id>/manifest.ts`
(Bun). Major-version mismatch with the running core is a boot failure.

### Gateway side (`:sukhi_fedi`)

Callback               | Default                | Purpose
-----------------------|------------------------|-------------------------------------
`id/0`                 | required               | atom matching the `.env` entry
`abi_version/0`        | `"1.0"`                | bumped by core on breaking changes
`depends_on/0`         | `[]`                   | ids that must also be enabled
`migrations_path/0`    | `priv/repo/migrations/addons/<id>/` | Ecto migration dir (nil if absent)
`supervision_children/0` | `[]`                 | processes started under `SukhiFedi.Supervisor`
`nats_subscriptions/0` | `[]`                   | `[{subject, {module, fn}}]`
`env_schema/0`         | `[]`                   | required/optional env var hints

Discovery: `SukhiFedi.Addon.Registry` scans compiled modules for the
`@sukhi_fedi_addon` persistent attribute and filters by
`ENABLED_ADDONS` / `DISABLE_ADDONS` env vars.

### API plugin-node side (`:sukhi_api`)

REST routes live on the plugin node as `SukhiApi.Capability`
implementations. Tag each capability with the addon id:

```elixir
use SukhiApi.Capability, addon: :mastodon_api
```

Capabilities without `:addon` are treated as core (always active).
`ENABLED_ADDONS` reaches the api node through docker-compose's
environment passthrough.

### Bun side

`bun/addons/<id>/manifest.ts` exports a `BunAddon` default:

```ts
import type { BunAddon } from "../types.ts";

const myAddon: BunAddon = {
  id: "my_addon",
  abi_version: "1.0",
  translators: {
    "my_addon.custom_note": handleBuildCustomNote,
  },
  subscribes: (subscribe) => [subscribe("ap.build.my_addon", handler)],
};
export default myAddon;
```

New addons are imported from `bun/addons/loader.ts` so they're picked
up at startup. Translator keys must be namespaced `<addon_id>.<type>`
to avoid clashing with the core names (`note`, `follow`, `accept`,
`announce`, `actor`, `dm`, `add`, `remove`).

## Migrations

- Per-addon: `elixir/priv/repo/migrations/addons/<id>/*.exs`.
- Core: `elixir/priv/repo/migrations/core/*.exs`.
- Runner: `SukhiFedi.Release.migrate_all/0` walks core first, then
  each enabled addon's path. Invoked by the container entrypoint on
  every start.
- **Disabling an addon does NOT roll migrations back.** Tables stay;
  re-enabling is a no-op DB-wise.
- **Cross-addon foreign keys are forbidden.** Addons may FK into core
  tables (`accounts`, `objects`) only. If addon A's table needs to
  reference addon B's table, merge them into one addon.

## Writing a new addon

1. Pick an id (`:my_feature`) and create
   `elixir/lib/sukhi_fedi/addons/my_feature.ex`:

   ```elixir
   defmodule SukhiFedi.Addons.MyFeature do
     use SukhiFedi.Addon, id: :my_feature

     @impl true
     def supervision_children, do: [SukhiFedi.Addons.MyFeature.Worker]
   end
   ```

2. (Optional) Add migrations under
   `elixir/priv/repo/migrations/addons/my_feature/*.exs`.

3. (Optional) Add REST routes as SukhiApi capabilities in
   `api/lib/sukhi_api/capabilities/` tagged with `addon: :my_feature`.

4. (Optional) Add a Bun-side manifest under `bun/addons/my_feature/`
   and register it in `bun/addons/loader.ts`.

5. Operators enable it by adding `my_feature` to `ENABLED_ADDONS` in
   their `.env` and `docker compose up -d`.

## Presets

Presets are named bundles of addon ids. Pick one (or several) with
`ADDON_PRESETS` and the matching addons turn on without spelling each
id into `ENABLED_ADDONS`.

```
# .env
ADDON_PRESETS=mastodon_compatible
ENABLED_ADDONS=              # optional: union with the preset
DISABLE_ADDONS=              # still wins (deny-list)
```

Precedence: `presets_expanded ∪ ENABLED_ADDONS` → then `DISABLE_ADDONS`
is subtracted by the registry. If `ENABLED_ADDONS=all` is set
**explicitly**, it wins and the preset becomes redundant; if it's left
unset (or empty), the preset is the effective allowlist.

Defined in `SukhiFedi.Addon.Presets` (gateway) and `SukhiApi.Addon.Presets`
(api node). Both maps are identical and must be kept in sync.

### `mastodon_compatible`

A Mastodon-API-shaped server. Capabilities for `:streaming` and
`:web_push` are still pending (TODO.md), but the addons themselves run
so the supervision tree is ready when those capabilities land.

| id               | role                                                         |
| ---------------- | ------------------------------------------------------------ |
| `:mastodon_api`  | REST capabilities (oauth, statuses, timelines, media, …)     |
| `:media`         | `/api/v1/media` uploads                                      |
| `:feeds`         | home / public / list timelines                               |
| `:moderation`    | block / mute / report / domain blocks                        |
| `:bookmarks`     | `/api/v1/bookmarks`                                          |
| `:pinned_notes`  | featured collection + pin endpoints                          |
| `:streaming`     | `/api/v1/streaming` WebSocket (`user` + `public:local` + `direct`) |
| `:web_push`      | push subscriptions (VAPID flow pending)                      |

Deliberately **not** included:

- `:articles` — ActivityPub `Article` type; not a Mastodon concept.
- `:misskey_api` — different API profile; use a separate preset.
- `:nodeinfo_monitor` — optional observability; belongs to
  `server_version_watcher`.

### `server_version_watcher`

Polls remote fediverse servers' NodeInfo and posts a bot Note when
their version changes.

| id                  | role                                                      |
| ------------------- | --------------------------------------------------------- |
| `:nodeinfo_monitor` | Oban cron + `MonitoredInstance` + version-change Notes    |
| `:feeds`            | so the bot Notes appear in home/public timelines          |
| `:pinned_notes`     | so the latest-version Note can be pinned to the bot actor |

## Rolling tags & Watchtower

Images are published to
`ghcr.io/<owner>/sukhi-fedi-{gateway,api,bun}` with
rolling tags:

- `:vX.Y.Z` — immutable, never moves
- `:vX.Y` — latest patch of a minor series
- `:vX` — latest minor of a major series (recommended Watchtower pin)
- `:latest` — always the newest tag pushed

Within a major, ABI-breaking changes are forbidden. A major bump
(`:v2`) signals callback removals/renames, schema-incompatible
migrations, or `object_type` renames — operators opt in by changing
their `SUKHI_VERSION` pin.
