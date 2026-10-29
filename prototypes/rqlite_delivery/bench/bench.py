# SPDX-License-Identifier: AGPL-3.0-or-later
# Needs a local 3-node rqlite (see README). Leader on 127.0.0.1:4011.
import http.client, json, re, time, os, subprocess, sys
import os
SQLF=os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "schema.sql")
text=open(SQLF).read()
head, *rest = re.split(r"^-- name: (\w+)\n", text, flags=re.M)
SQL=dict(zip(rest[::2], rest[1::2]))
ddl=[s.strip() for s in re.sub(r"^--.*$","",head,flags=re.M).split(";") if s.strip()]
c=http.client.HTTPConnection("127.0.0.1",4011,timeout=120)
def post(path, body):
    c.request("POST", path, json.dumps(body), {"Content-Type":"application/json"})
    r=c.getresponse(); d=json.loads(r.read())
    return d
def ex(stmts, tx=False): 
    d=post("/db/execute"+("?transaction" if tx else ""), stmts)
    for r in d["results"]:
        if "error" in r: raise RuntimeError(r["error"])
    return d
def rss():
    out=subprocess.run(["ps","-C","rqlited","-o","rss="],capture_output=True,text=True).stdout.split()
    return [int(x)//1024 for x in out]
def bind(name, **kw):
    s=SQL[name].strip().rstrip(";")
    return [s, kw]
print("rss at start (MB per node):", rss())
for s in ddl: ex([s])
B=64
ex([["INSERT INTO bucket (bucket, owner, epoch, lease_until) VALUES (?, 'a', 1, 9999999999999)", b] for b in range(B)], tx=True)

# a) single INSERT per request (one Raft commit each)
n=1000; t=time.perf_counter()
for i in range(n):
    ex([["INSERT INTO jobs (bucket, host, run_at, payload) VALUES (?,?,?,?)", i%B, f"h{i%1000}.example", 0, "x"]])
dt=time.perf_counter()-t; print(f"A. single INSERT/request: {dt*1000/n:.2f} ms each ({n/dt:.0f}/s)")

# b) bulk load: 100 requests x 500 statements (one transaction each)
t=time.perf_counter(); N=50000; K=500
for k in range(N//K):
    ex([["INSERT INTO jobs (bucket, host, run_at, payload) VALUES (?,?,?,?)", (k*K+j)%B, f"h{(k*K+j)%1000}.example", 0, "x"] for j in range(K)], tx=True)
dt=time.perf_counter()-t; print(f"B. bulk load {N} rows ({K} stmts/request, transaction): {dt:.2f}s ({N/dt:.0f} rows/s)")
print("   rss after load:", rss())

# c) claim with RETURNING, batches of 50
def claim(n, now):
    d=post("/db/request", [[SQL["claim"].strip().rstrip(";"), {"me":"a","now":now,"job_lease_ms":30000,"n":n}]])
    r=d["results"][0]
    if "error" in r: raise RuntimeError(r["error"])
    return r.get("values") or []
lat=[]; got=0; ids=[]
t0=time.perf_counter()
while True:
    t=time.perf_counter(); rows=claim(50, 1); lat.append(time.perf_counter()-t)
    if not rows: break
    got+=len(rows); ids+= [r[0] for r in rows]
    if len(ids)>=2000: break
dt=time.perf_counter()-t0
lat.sort(); print(f"C. claim 50 at a time: {len(lat)} requests, {got} jobs, {got/dt:.0f} jobs/s, p50 {lat[len(lat)//2]*1000:.1f} ms p99 {lat[int(len(lat)*.99)-1]*1000:.1f} ms")

# d) complete in batches of 50 ids
t=time.perf_counter(); reqs=0
for i in range(0,len(ids),50):
    chunk=ids[i:i+50]
    ex([[f"UPDATE jobs SET state='completed', lease_until=NULL, unique_key=NULL WHERE id IN ({','.join('?'*len(chunk))}) AND state='claimed' AND claimed_by='a'", *chunk]]); reqs+=1
dt=time.perf_counter()-t; print(f"D. complete 50 ids/request: {reqs} requests, {len(ids)/dt:.0f} jobs/s, {dt*1000/reqs:.1f} ms each")

# e) read latencies
for lvl in ("none","weak","strong"):
    t=time.perf_counter()
    for i in range(300):
        c.request("GET", f"/db/query?level={lvl}&q="+"SELECT%20count(*)%20FROM%20jobs%20WHERE%20bucket%3D3%20AND%20state%3D%27ready%27"); c.getresponse().read()
    print(f"E. read level={lvl}: {(time.perf_counter()-t)*1000/300:.2f} ms")
print("rss at end (MB per node):", rss())
