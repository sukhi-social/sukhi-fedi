// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Prototype: the "which job may run now?" rules of a delivery queue,
// written once as full-relation rules and maintained incrementally by DBSP.
//
//   eligible(job) :- available(host, job),
//                    not saturated(host),
//                    not blocked_parent(job).
//   saturated(host)     :- count(running(host, _)) >= LIMIT.
//   blocked_parent(p)   :- child(p, c), not done(c).
//
// Durability, atomic claim, and the clock are NOT here: the clock arrives as
// facts (a job becomes `available` when its run_at passes), the log lives in
// SQLite/Mnesia, and the claim is a store transaction.

use dbsp::{OrdZSet, OutputHandle, Runtime, typed_batch::{IndexedZSetReader, SpineSnapshot}, utils::Tup2};
use std::collections::{HashMap, HashSet};
use std::time::Instant;

type Host = u32;
type JobId = u64;

const LIMIT: i64 = 4;

struct Facts {
    available: dbsp::ZSetHandle<Tup2<Host, JobId>>,
    running: dbsp::ZSetHandle<Tup2<Host, JobId>>,
    child: dbsp::ZSetHandle<Tup2<JobId, JobId>>, // (parent, child)
    done: dbsp::ZSetHandle<JobId>,               // child done
}

fn build(threads: usize) -> (dbsp::DBSPHandle, Facts, OutputHandle<SpineSnapshot<OrdZSet<JobId>>>) {
    let (h, (facts, out)) = Runtime::init_circuit(threads, |c| {
        let (available, available_h) = c.add_input_zset::<Tup2<Host, JobId>>();
        let (running, running_h) = c.add_input_zset::<Tup2<Host, JobId>>();
        let (child, child_h) = c.add_input_zset::<Tup2<JobId, JobId>>();
        let (done, done_h) = c.add_input_zset::<JobId>();

        // saturated(host): a set, via (host, count) with count >= LIMIT.
        let saturated = running
            .map(|Tup2(host, _)| *host)
            .weighted_count()
            .filter(|(_, n)| *n >= LIMIT);

        // blocked_parent(p): has a child that is not done.
        //   pending = child - (child semijoin done);  blocked = keys of pending
        let child_by_c = child.map_index(|Tup2(p, c)| (*c, *p));
        let done_by_c = done.map_index(|c| (*c, ()));
        let done_pairs = child_by_c.join(&done_by_c, |c, p, _| Tup2(*p, *c));
        let pending = child.minus(&done_pairs);
        let blocked = pending.map(|Tup2(p, _)| *p).weighted_count();

        // available - (available semijoin saturated), then the same for blocked.
        let by_host = available.map_index(|Tup2(h, j)| (*h, *j));
        let on_sat = by_host.join(&saturated, |h, j, _| Tup2(*h, *j));
        let not_sat = available.minus(&on_sat);

        let by_job = not_sat.map_index(|Tup2(h, j)| (*j, *h));
        let on_blocked = by_job.join(&blocked, |j, h, _| Tup2(*h, *j));
        let eligible = not_sat.minus(&on_blocked).map(|Tup2(_, j)| *j);

        Ok((
            Facts { available: available_h, running: running_h, child: child_h, done: done_h },
            eligible.accumulate_output(),
        ))
    })
    .unwrap();
    (h, facts, out)
}

fn eligible_set(out: &OutputHandle<SpineSnapshot<OrdZSet<JobId>>>, cur: &mut HashSet<JobId>) {
    // A transaction runs as several microsteps; `accumulate_output` gives one
    // output per transaction. The snapshot is not consolidated, so sum weights.
    let mut net: HashMap<JobId, i64> = HashMap::new();
    for (j, _, w) in out.concat().iter() {
        *net.entry(j).or_default() += w;
    }
    for (j, w) in net {
        if w > 0 { cur.insert(j); } else if w < 0 { cur.remove(&j); }
    }
}

/// Plain recompute-from-scratch reference, used as oracle and baseline.
struct Naive {
    available: HashSet<(Host, JobId)>,
    running: HashSet<(Host, JobId)>,
    child: HashSet<(JobId, JobId)>,
    done: HashSet<JobId>,
}
impl Naive {
    fn eligible(&self) -> HashSet<JobId> {
        let mut per_host: HashMap<Host, i64> = HashMap::new();
        for (h, _) in &self.running { *per_host.entry(*h).or_default() += 1; }
        let blocked: HashSet<JobId> = self.child.iter()
            .filter(|(_, c)| !self.done.contains(c)).map(|(p, _)| *p).collect();
        self.available.iter()
            .filter(|(h, j)| per_host.get(h).copied().unwrap_or(0) < LIMIT && !blocked.contains(j))
            .map(|(_, j)| *j).collect()
    }
}

fn rss_mb() -> f64 {
    std::fs::read_to_string("/proc/self/status").ok()
        .and_then(|s| s.lines().find(|l| l.starts_with("VmRSS:")).map(|l| l.to_string()))
        .and_then(|l| l.split_whitespace().nth(1).and_then(|n| n.parse::<f64>().ok()))
        .map(|kb| kb / 1024.0).unwrap_or(0.0)
}

fn main() -> anyhow::Result<()> {
    let n_jobs: u64 = std::env::args().nth(1).and_then(|s| s.parse().ok()).unwrap_or(100_000);
    let hosts: u32 = 1_000;
    let parents = n_jobs / 20; // every 20th job is a batch parent with 8 children

    let (mut dbsp, f, out) = build(1);
    let mut naive = Naive { available: HashSet::new(), running: HashSet::new(), child: HashSet::new(), done: HashSet::new() };
    let mut cur = HashSet::new();

    // ---- initial load
    let t = Instant::now();
    for j in 0..n_jobs {
        let h = (j % hosts as u64) as Host;
        f.available.push(Tup2(h, j), 1);
        naive.available.insert((h, j));
    }
    for p in 0..parents {
        for k in 0..8 {
            let c = n_jobs + p * 8 + k;
            f.child.push(Tup2(p * 20, c), 1);
            naive.child.insert((p * 20, c));
        }
    }
    dbsp.transaction()?;
    eligible_set(&out, &mut cur);
    println!("load {} jobs + {} batch edges: {:?}, eligible={}, RSS={:.0} MB",
        n_jobs, parents * 8, t.elapsed(), cur.len(), rss_mb());
    assert_eq!(cur, naive.eligible());

    // ---- small ticks: start 50 jobs, finish some children, return some
    let ticks = 200;
    let (mut t_dbsp, mut t_naive) = (std::time::Duration::ZERO, std::time::Duration::ZERO);
    let mut next = 0u64;
    let mut child_i = 0u64;
    for tick in 0..ticks {
        for _ in 0..50 {
            // start the next eligible-looking job on its host
            let j = next % n_jobs; next += 7;
            let h = (j % hosts as u64) as Host;
            if naive.available.remove(&(h, j)) {
                f.available.push(Tup2(h, j), -1);
                naive.running.insert((h, j));
                f.running.push(Tup2(h, j), 1);
            }
        }
        for _ in 0..10 {
            let c = n_jobs + (child_i % (parents * 8)); child_i += 3;
            if naive.done.insert(c) { f.done.push(c, 1); }
        }
        // some running jobs finish
        let finish: Vec<_> = naive.running.iter().take(30).cloned().collect();
        for (h, j) in finish {
            naive.running.remove(&(h, j));
            f.running.push(Tup2(h, j), -1);
        }
        let t = Instant::now();
        dbsp.transaction()?;
        eligible_set(&out, &mut cur);
        t_dbsp += t.elapsed();

        let t = Instant::now();
        let want = naive.eligible();
        t_naive += t.elapsed();
        if cur != want {
            let missing = want.difference(&cur).count();
            let extra = cur.difference(&want).count();
            panic!("diverged at tick {tick}: incremental={} recompute={} missing={missing} extra={extra}", cur.len(), want.len());
        }
    }
    println!("{ticks} ticks (~90 fact changes each): dbsp {:?} total ({:?}/tick), recompute {:?} total ({:?}/tick), RSS={:.0} MB",
        t_dbsp, t_dbsp / ticks, t_naive, t_naive / ticks, rss_mb());
    println!("incremental == recompute on every tick: OK");
    dbsp.kill().unwrap();
    Ok(())
}
