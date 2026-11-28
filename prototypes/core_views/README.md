# Core views prototype

sukhi's notes, follows, boosts, reactions and home / public / tag timelines, written as **views of
facts** on the newer `ecto_hosi` (hosigraph `266b4f2`), to see what fits before porting every
schema. Nothing in `elixir/` uses it, and `elixir/` stays on `ecto_hosi` 0.2.0.

```sh
mix deps.get
HOSI_BUILD=none mix test                      # in-memory stand-in
HOSI_BUILD=source HOSI_REAL=1 HOSI_JAR=/path/datalevin-standalone.jar mix test
HOSI_REAL=1 PROBE_SIZE=20000 MIX_ENV=test mix run script/probe.exs
```

The last two need libhosi (and `HOSI_JAVA` if `java` is older than 21). `ECTO_HOSI_PATH` and
`HOSI_PATH` use a local hosigraph checkout. After changing `HOSI_BUILD`, run
`mix deps.compile hosi --force`.

## Mapping

| sukhi today | Here |
|---|---|
| table | `ap/type`: `note`, `announce`, `like`, `follow`, `tombstone` |
| `notes.ap_id` | `ap/uri` (unique, set once) |
| `notes.account_id` | `ap/attributed-to`, and `hosi/owner` |
| boost / reaction `account_id`, `note_id` | `ap/actor`, `ap/object` |
| reaction `emoji` | `ap/content` |
| `follows.followee_id` | `ap/object` |
| `follows.follower_uri`, `state` | `follow/actor-uri`, `follow/state` |
| (none) | follow `follower_id` = `ap/actor`, and `hosi/owner` |
| `note_media`, `note_tags`, `tags` | `ap/attachment`, `ap/tag`: many values on the note |
| `created_at` | `ap/registered-at`; boosts: `announce/at` |
| note delete | tombstone; boosts and reactions of the note go in the same write |

`ap/actor`, `ap/object` and `ap/content` are not in the hosigraph plan's attribute table yet.

## IDs

From `sukhi_id_s1_section_draft.md`. Code: `ids.ex`, `records.ex`.

| Attribute | Field | Local record | Remote record |
|---|---|---|---|
| `ap/uuid`: the primary ID | `uuid` | new UUIDv7 | new UUIDv7 |
| `ap/id`: the API ID | `api_id` | `s1k..`, 35 characters, from the UUID | `s0kza..`, 31 characters, from the URI |
| `ap/short-id` | `short_id` | first 24 characters of `ap/id` | none |

* All three are unique and set once. A deleted note keeps them on its tombstone.
* hosigraph's integer `:id` stays underneath: references, joins and ordering use it.
* A note with a `domain` is remote. A boost, reaction or follow says so with `remote: true`.
* `Records.resolve/1` takes a canonical, short or longer local ID, also in the grouped or
  upper-case form, or an `s0kza` ID. A taken short ID gets a new UUIDv7 (`Records.insert/2`).
* Timelines take `max_id`, `since_id` and `min_id` as API IDs.

Open, or not as the draft has it:

1. **The text of an API ID does not sort by time** (`s0kza` is a hash; `s1` starts with the type).
   The server looks the record up to page. A client that compares IDs itself would be wrong.
2. **A deleted remote record gives no place:** paging from the `s0kza` ID of an undone boost
   answers an empty page. An undone local one answers from the time in its `s1` ID, which can
   differ slightly from the boost's `created_at`.
3. **`insert_all` and direct writes make no IDs.** Only the changesets do.
4. **The changesets accept `uuid` and `remote` from their attributes**, so the app must not pass a
   client's parameters through for them.
5. The padding side of `s0kza` is not in the draft: padded on the left here.
6. Not built: `ap/compat-id`, `ap/alt-id`, the `s0kin` / `s0kex` aliases, remote fetch, the
   proposed counter rule, and stamping `ap/uri` on local records.

## What fits

* Accounts can stay in PostgreSQL: a reference to an account id (2 and up) is accepted.
* `EXISTS (SELECT 1 FROM note_media ..)` becomes `not is_nil(n.media_ids)`; the `note_tags` join
  becomes `^tag in n.tags`.
* The timeline code keeps its shape: `highest_in` for candidates, Ecto queries for the gates.

## What does not fit as it is

1. **Unique rules cross types.** Boosts, reactions and follows share `ap/actor` and `ap/object`.
   The boost rule as a hosigraph tuple refused a second emoji reaction. Here each rule has
   `where: [eq: [type: ..]]`, which the adapter keeps: a direct hosigraph write passes it by.
2. **Indexes cross types.** With boosts and reactions on one (actor, time) index, reading 5 boosts
   behind 10,000 newer reactions took 12.7 s (1.2 ms without them). With `announce/at`: 1.4 ms.
   Every shared pair used in a `hosi_tuple` needs this check.
3. **A follow needs the follower's account id** to have an owner; a write without it is refused.
   `SukhiFedi.Schema.Follow` has only the URI, and the inbound `Follow` path writes it before the
   actor is resolved.
4. **`erase_account` does not take a PostgreSQL account** (`{:error, :stale}`). Erasing by
   `hosi/owner` removes what the account made, but leaves others' follows of it and others'
   boosts of its notes. sukhi would have to remove those itself.
5. **Long id lists fail.** `id in ^ids` plus another condition did not compile in Datalevin at
   10,240 ids (5,120 worked). sukhi's "ask again for twice as many" reaches that for a gate that
   matches almost nothing. Here the walk goes on from the last place in steps of at most 2,000.
   From reading the code, 0.2.0 writes the same clause; not run on 0.2.0.
6. **Attachments lose their order**: many values are a set.
7. **The stand-in's ids do not sort by time**, so id paging and the note / boost merge are tested
   on the real engine only.
8. **Follows by remote actors without a PostgreSQL account** have no owner to give; not designed.

9. **Equal times slow the walk.** With 11,000 notes of one second, each further 2,000-place step
   of `highest_in` took longer, up to 5.06 s against a 5 s timeout (the same without the IDs). The
   test now spaces them a second apart.

## Timings

20,000 public notes by 100 authors, a viewer who follows 50; Datalevin 1.2.10 on a JVM, Linux
aarch64, median of 5. One machine, one run.

| Read | Time |
|---|---|
| home | 18 ms |
| home with a keyword gate | 16 ms |
| home with `only_media`, nothing matches (walks everything) | 1.4 s |
| public, as sukhi queries it (`order_by` + `limit`) | 1.1 s |
| newest 100 by `Repo.highest(:"ap/registered-at", ..)` | 6 ms |

`public` here is still the query. Moving it to `Repo.highest` is the likely fix; that index also
holds follows and reactions, so it needs the same check as item 2. 0.2.0 was not timed.

## Left out

Lists, blocks and mutes (their id lists come in as options), the bubble timeline, preloads, boost
wrappers' accounts, caching, `with_refs`, HTML sanitizing, and the other note fields. Nothing
converts existing data. The timings above were taken before the IDs were added.

## One difference from `SukhiFedi.Timelines`

`boost_account_ids` there is `following -- (excluded -- (hide_boosts -- hidden))`. `--` is
right-associative, so a list's "hide boosts" does nothing, and boosts by blocked or muted accounts
are not dropped. This prototype drops them. `elixir/` is not changed.
