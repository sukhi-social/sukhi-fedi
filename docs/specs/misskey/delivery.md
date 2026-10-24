<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# Misskey: Delivery

- Part of [the Misskey specification](README.md); source tags and terms are explained there.

## In one paragraph

Misskey puts each outgoing activity in a queue with one job per receiving inbox, and retries a failed job with growing delays for about a day and a third. It stops sending to a server that has been silent for a week, or that says 410 on its shared inbox.

## Who gets an activity

**[src]** `core/activitypub/ApDeliverManagerService.ts`, `core/QueueService.ts`

- An activity addressed to the actor's followers goes to each remote follower's shared inbox if it has one, else its personal inbox. One job per distinct inbox, so a server with many followers gets one copy.
- An activity addressed to named users (mentions, the owner of a poll, a followee, the target of a block) goes to each user's inbox, unless the shared inbox is already in the list.
- Some activities also go to the relays Misskey follows.
- Misskey skips an inbox whose host is blocked, whose server is suspended (by admin, as gone, or after a week of silence), or whose software is on the delivery-suspended list.

## Retries

**[src]** `core/QueueService.ts`, `queue/QueueProcessorService.ts`, `queue/processors/DeliverProcessorService.ts`

- A job has 12 attempts by default. After attempt `n` it waits `(2^n - 1)` minutes, at most 8 hours, plus a random 0 to 20 percent. The waits are 1, 3, 7, 15, 31, 63, 127, 255, then 480 minutes three times: 1942 minutes, about 1.35 days (about 1.6 with the maximum jitter).
- Misskey retries on a network error, a timeout, a 5xx, and a 429. It does not retry any other 4xx; the job ends.
- A 410 from a shared inbox also marks the whole server as gone, and Misskey stops sending to it.
- When a delivery fails, Misskey marks the server as not responding. If it stays that way for a week, Misskey suspends it (`autoSuspendedForNotResponding`). The next success clears the mark.

## Things to watch

- A sender that retries for much less than a day can lose a delivery to a server that is down.
- A server that answers 4xx (other than 429) to a valid delivery gets no second try.
