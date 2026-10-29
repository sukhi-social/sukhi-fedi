# SPDX-License-Identifier: AGPL-3.0-or-later
# Needs a local 3-node rqlite (see README). Leader on 127.0.0.1:4011.
import http.client, json, time, subprocess
def try_write(port):
    try:
        c=http.client.HTTPConnection("127.0.0.1",port,timeout=2)
        c.request("POST","/db/execute",json.dumps([["INSERT INTO jobs (bucket, host, run_at, payload) VALUES (1,'f.example',0,'failover')"]]),{"Content-Type":"application/json"})
        r=c.getresponse(); d=json.loads(r.read()); return "error" not in d["results"][0]
    except Exception: return False
leader=subprocess.run(["pgrep","-f","node-id n1"],capture_output=True,text=True).stdout.split()[0]
print("killing leader n1 pid",leader)
t=time.perf_counter(); subprocess.run(["kill","-9",leader])
fails=0
while not try_write(4021):
    fails+=1; time.sleep(0.05)
print(f"writes via n2 succeeded again after {time.perf_counter()-t:.2f}s ({fails} failed attempts)")
c=http.client.HTTPConnection("127.0.0.1",4021); c.request("GET","/nodes"); d=json.loads(c.getresponse().read())
print({k:(v.get("reachable"),v.get("leader")) for k,v in d.items()})
