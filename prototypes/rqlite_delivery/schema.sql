-- SPDX-License-Identifier: AGPL-3.0-or-later
--
-- Delivery queue + "which node delivers to which host" on a replicated SQLite
-- (rqlite). Every statement below is ONE statement, so one Raft commit, so atomic.
-- Parameters (:name) are bound by the caller; `now` is ms and is passed in.

CREATE TABLE node (
  node_id     TEXT PRIMARY KEY,
  lease_until INTEGER NOT NULL            -- heartbeat
);

-- Fixed number of buckets; host -> bucket never changes: bucket = hash(host) % B.
-- Only the OWNER column moves when nodes join or leave.
CREATE TABLE bucket (
  bucket      INTEGER PRIMARY KEY,
  owner       TEXT,
  epoch       INTEGER NOT NULL DEFAULT 0, -- bumped on every change of owner
  lease_until INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE jobs (
  id           INTEGER PRIMARY KEY,
  bucket       INTEGER NOT NULL,
  host         TEXT    NOT NULL,
  state        TEXT    NOT NULL DEFAULT 'ready',   -- ready | claimed | completed | dead
  run_at       INTEGER NOT NULL,
  attempt      INTEGER NOT NULL DEFAULT 0,
  max_attempts INTEGER NOT NULL DEFAULT 10,
  lease_until  INTEGER,
  claimed_by   TEXT,
  unique_key   TEXT UNIQUE,                         -- NULLs do not collide
  payload      TEXT NOT NULL,
  last_error   TEXT
);
CREATE INDEX jobs_ready ON jobs (bucket, state, run_at);
CREATE INDEX jobs_lease ON jobs (state, lease_until);

-- name: heartbeat
INSERT INTO node (node_id, lease_until) VALUES (:me, :now + :lease_ms)
ON CONFLICT (node_id) DO UPDATE SET lease_until = excluded.lease_until;

-- name: live_nodes
SELECT node_id FROM node WHERE lease_until > :now ORDER BY node_id;

-- name: acquire_bucket
-- Take a bucket I should own (rendezvous hashing, computed by the caller) when it
-- is mine already, expired, or owned by a node that is no longer live.
UPDATE bucket
   SET owner = :me,
       epoch = CASE WHEN owner = :me THEN epoch ELSE epoch + 1 END,
       lease_until = :now + :lease_ms
 WHERE bucket = :bucket
   AND (owner = :me OR owner IS NULL OR lease_until <= :now
        OR owner NOT IN (SELECT node_id FROM node WHERE lease_until > :now));

-- name: release_bucket
-- Hand a bucket back after draining it (I am no longer its rendezvous winner).
UPDATE bucket SET lease_until = 0 WHERE bucket = :bucket AND owner = :me;

-- name: claim
-- The fence is in the statement: only buckets whose lease I hold *right now*.
-- Per-host concurrency is enforced by the caller: one owner per bucket means one
-- process sees all in-flight jobs of a host, so the cap is a local counter.
UPDATE jobs
   SET state = 'claimed', attempt = attempt + 1,
       lease_until = :now + :job_lease_ms, claimed_by = :me
 WHERE id IN (
         SELECT j.id FROM jobs j
          WHERE j.state = 'ready' AND j.run_at <= :now
            AND j.bucket IN (SELECT bucket FROM bucket WHERE owner = :me AND lease_until > :now)
          ORDER BY j.run_at
          LIMIT :n)
RETURNING id, host, bucket, attempt, payload;

-- name: complete
UPDATE jobs SET state = 'completed', lease_until = NULL, unique_key = NULL
 WHERE id = :id AND state = 'claimed' AND claimed_by = :me;

-- name: fail_retry
UPDATE jobs
   SET state = CASE WHEN attempt >= max_attempts THEN 'dead' ELSE 'ready' END,
       run_at = :now + MIN(1000 << attempt, 21600000),
       lease_until = NULL, last_error = :err,
       unique_key = CASE WHEN attempt >= max_attempts THEN NULL ELSE unique_key END
 WHERE id = :id AND state = 'claimed' AND claimed_by = :me;

-- name: lifeline
-- Any node may run this: claims past their lease go back (or die at the limit).
UPDATE jobs
   SET state = CASE WHEN attempt >= max_attempts THEN 'dead' ELSE 'ready' END,
       run_at = :now, lease_until = NULL, claimed_by = NULL, last_error = 'lease_expired',
       unique_key = CASE WHEN attempt >= max_attempts THEN NULL ELSE unique_key END
 WHERE state = 'claimed' AND lease_until <= :now;
