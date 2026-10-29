# SPDX-License-Identifier: AGPL-3.0-or-later
"""
Runs schema.sql's statements against plain SQLite (3.35+ for RETURNING) as a
stand-in for rqlite: the same SQL engine, each statement atomic. It checks the
*logic* (exclusive claims, fencing, failover, minimal rebalance). It says nothing
about rqlite's latency, throughput or memory.

    python3 -I sim.py
"""
import hashlib
import re
import sqlite3
import unittest
from collections import Counter

B = 64  # buckets
LEASE = 10_000
JOB_LEASE = 30_000


def load_sql():
    text = open(__file__.replace("sim.py", "schema.sql")).read()
    head, *rest = re.split(r"^-- name: (\w+)\n", text, flags=re.M)
    stmts = dict(zip(rest[::2], rest[1::2]))
    return head, stmts


DDL, SQL = load_sql()


def h(s):
    return int.from_bytes(hashlib.sha256(s.encode()).digest()[:8], "big")


def bucket_of(host):
    return h(host) % B


def rendezvous_owner(bucket, nodes):
    """Highest-random-weight hashing: the winner for a bucket among live nodes."""
    return max(nodes, key=lambda n: h(f"{bucket}/{n}"))


class Node:
    def __init__(self, db, name):
        self.db, self.name = db, name

    def q(self, name, **kw):
        kw.setdefault("me", self.name)
        cur = self.db.execute(SQL[name], kw)
        return cur.fetchall()

    def tick(self, now):
        """heartbeat + ownership: acquire what I win, release what I lost."""
        self.q("heartbeat", now=now, lease_ms=LEASE)
        live = [r[0] for r in self.q("live_nodes", now=now)]
        for b in range(B):
            if rendezvous_owner(b, live) == self.name:
                self.db.execute(SQL["acquire_bucket"], dict(me=self.name, bucket=b, now=now, lease_ms=LEASE))
            else:
                self.db.execute(SQL["release_bucket"], dict(me=self.name, bucket=b))

    def claim(self, now, n=50):
        return self.q("claim", now=now, job_lease_ms=JOB_LEASE, n=n)


def new_db():
    db = sqlite3.connect(":memory:", isolation_level=None)
    db.executescript(DDL)
    for b in range(B):
        db.execute("INSERT INTO bucket (bucket) VALUES (?)", (b,))
    return db


def add_jobs(db, hosts, n, run_at=0):
    for i in range(n):
        host = hosts[i % len(hosts)]
        db.execute(
            "INSERT INTO jobs (bucket, host, run_at, payload) VALUES (?,?,?,?)",
            (bucket_of(host), host, run_at, f"job{i}"),
        )


def owners(db):
    return {b: o for b, o in db.execute("SELECT bucket, owner FROM bucket")}


class Sim(unittest.TestCase):
    def test_claims_are_exclusive_and_within_owned_buckets(self):
        db = new_db()
        hosts = [f"h{i}.example" for i in range(200)]
        add_jobs(db, hosts, 5000)
        nodes = [Node(db, n) for n in ("a", "b", "c")]
        for n in nodes:
            n.tick(0)
        for n in nodes:
            n.tick(1)  # second round: everyone has heartbeated, ownership settles
        mine = {n.name: {b for b, o in owners(db).items() if o == n.name} for n in nodes}
        self.assertEqual(sum(len(v) for v in mine.values()), B)

        seen = Counter()
        progress = True
        while progress:
            progress = False
            for n in nodes:  # interleaved
                for (jid, host, bucket, attempt, _p) in n.claim(100, n=37):
                    seen[jid] += 1
                    self.assertIn(bucket, mine[n.name])
                    progress = True
        self.assertEqual(len(seen), 5000)
        self.assertEqual(set(seen.values()), {1})

    def test_expired_lease_is_fenced_in_the_statement(self):
        db = new_db()
        add_jobs(db, [f"h{i}.example" for i in range(50)], 500)
        a, b = Node(db, "a"), Node(db, "b")
        a.tick(0)  # a alone owns every bucket
        self.assertEqual(len(a.claim(1, n=10)), 10)
        # a stalls (GC pause, partition). Its bucket leases lapse; b takes over.
        t = LEASE + 100
        b.tick(t)
        self.assertEqual(set(owners(db).values()), {"b"})
        # a wakes up and, not knowing, tries to claim: the statement itself refuses.
        self.assertEqual(a.claim(t, n=10), [])
        self.assertGreater(len(b.claim(t, n=10)), 0)

    def test_failover_redelivers_orphaned_claims(self):
        db = new_db()
        add_jobs(db, [f"h{i}.example" for i in range(50)], 300)
        a, b = Node(db, "a"), Node(db, "b")
        a.tick(0)
        b.tick(0)
        a.tick(1)
        b.tick(1)
        got = a.claim(2, n=40)  # `a` dies holding these
        self.assertGreater(len(got), 0)
        t = JOB_LEASE + 10
        b.tick(t)  # a is no longer live -> b takes all its buckets
        self.assertEqual(set(owners(db).values()), {"b"})
        db.execute(SQL["lifeline"], dict(now=t))
        redo = {jid: attempt for jid, _h, _b, attempt, _p in b.claim(t, n=1000)}
        for jid, *_ in got:
            self.assertEqual(redo[jid], 2, "orphaned job was delivered a second time, attempt=2")

    def test_rebalance_moves_only_about_one_nth_of_buckets(self):
        before = {b: rendezvous_owner(b, ["a", "b", "c"]) for b in range(B)}
        after = {b: rendezvous_owner(b, ["a", "b", "c", "d"]) for b in range(B)}
        moved = [b for b in range(B) if before[b] != after[b]]
        self.assertTrue(all(after[b] == "d" for b in moved), "buckets only move TO the new node")
        self.assertLessEqual(len(moved), B // 4 + 8)
        gone = {b: rendezvous_owner(b, ["a", "b"]) for b in range(B)}
        moved2 = [b for b in range(B) if before[b] != gone[b]]
        self.assertTrue(all(before[b] == "c" for b in moved2), "only the removed node's buckets move")

    def test_unique_key_and_retry_to_dead(self):
        db = new_db()
        host = "h.example"
        ins = "INSERT OR IGNORE INTO jobs (bucket, host, run_at, payload, unique_key, max_attempts) VALUES (?,?,?,?,?,2)"
        self.assertEqual(db.execute(ins, (bucket_of(host), host, 0, "x", "act-1|inbox")).rowcount, 1)
        self.assertEqual(db.execute(ins, (bucket_of(host), host, 0, "x", "act-1|inbox")).rowcount, 0)
        a = Node(db, "a")
        a.tick(0)
        [(jid, *_)] = a.claim(1)
        a.q("fail_retry", id=jid, now=1, err="timeout")
        self.assertEqual(db.execute("SELECT state, run_at FROM jobs").fetchone(), ("ready", 1 + 2000))
        [(jid, *_)] = a.claim(2001)
        a.q("fail_retry", id=jid, now=2001, err="timeout")
        self.assertEqual(db.execute("SELECT state FROM jobs").fetchone(), ("dead",))
        self.assertEqual(db.execute(ins, (bucket_of(host), host, 0, "x", "act-1|inbox")).rowcount, 1)


if __name__ == "__main__":
    unittest.main(verbosity=2)
