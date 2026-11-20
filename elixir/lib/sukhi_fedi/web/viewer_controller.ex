# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Web.ViewerController do
  @moduledoc """
  Minimal HTML frontend + JSON proxy for looking up any fediverse
  server's NodeInfo. The JSON endpoint shares the existing
  `NodeinfoFetcher` cache with the `nodeinfo_monitor` addon so
  repeated lookups are cheap.
  """

  import Plug.Conn
  import Ecto.Query

  alias SukhiFedi.Accounts
  alias SukhiFedi.Addons.NodeinfoMonitor
  alias SukhiFedi.Addons.NodeinfoMonitor.NodeinfoFetcher
  alias SukhiFedi.{Repo, Schema.Account}

  def home(conn, _opts) do
    domain = SukhiFedi.Config.domain!()

    conn
    |> put_resp_content_type("text/html; charset=utf-8")
    |> send_resp(200, page_html(domain))
  end

  def list_watchers(conn, _opts) do
    domain = SukhiFedi.Config.domain!()

    watchers =
      Account
      |> where([a], not is_nil(a.monitored_domain))
      |> order_by(asc: :monitored_domain)
      |> Repo.all()
      |> Enum.map(fn a ->
        %{
          username: a.username,
          display_name: a.display_name,
          monitored_domain: a.monitored_domain,
          summary: a.summary,
          handle: "@#{a.username}@#{domain}",
          actor_url: "https://#{domain}/users/#{a.username}"
        }
      end)

    send_json(conn, 200, %{watchers: watchers})
  end

  def register_watcher(conn, _opts) do
    with raw when is_binary(raw) <- conn.params["domain"] || :missing,
         domain <- normalize_domain(raw),
         true <- valid_domain?(domain),
         {:ok, snap} <- NodeinfoFetcher.fetch(domain) do
      status = if Accounts.by_monitored_domain(domain), do: :already_exists, else: :created

      case NodeinfoMonitor.register_and_record(domain, snap) do
        {:ok, _mi, account} ->
          self_domain = SukhiFedi.Config.domain!()

          send_json(conn, 200, %{
            status: to_string(status),
            username: account.username,
            handle: "@#{account.username}@#{self_domain}",
            domain: domain,
            software_name: snap.software_name,
            version: snap.version
          })

        {:error, reason} ->
          send_json(conn, 502, %{error: "register failed", reason: inspect(reason)})
      end
    else
      :missing ->
        send_json(conn, 400, %{error: "missing 'domain'"})

      false ->
        send_json(conn, 400, %{error: "invalid domain"})

      {:error, reason} ->
        send_json(conn, 502, %{error: "nodeinfo fetch failed", reason: inspect(reason)})
    end
  end

  def nodeinfo_lookup(conn, _opts) do
    case conn.params["domain"] do
      nil ->
        send_json(conn, 400, %{error: "missing 'domain' query parameter"})

      "" ->
        send_json(conn, 400, %{error: "empty domain"})

      raw ->
        domain = normalize_domain(raw)

        if valid_domain?(domain) do
          case NodeinfoFetcher.fetch(domain) do
            {:ok, snap} ->
              send_json(conn, 200, %{
                domain: domain,
                software_name: snap.software_name,
                version: snap.version,
                raw: snap.raw
              })

            {:error, reason} ->
              send_json(conn, 502, %{domain: domain, error: inspect(reason)})
          end
        else
          send_json(conn, 400, %{error: "invalid domain", input: raw})
        end
    end
  end

  defp send_json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, JSON.encode!(body))
  end

  defp normalize_domain(raw) do
    raw
    |> String.trim()
    |> String.replace_prefix("https://", "")
    |> String.replace_prefix("http://", "")
    |> String.trim_trailing("/")
    |> String.downcase()
  end

  # Keep liberal (punycode/hostnames/ports) but reject anything with a
  # slash, space, or scheme — the fetcher puts the value into a URL.
  defp valid_domain?(domain) do
    Regex.match?(~r/^[a-z0-9\.\-:]+$/i, domain) and String.contains?(domain, ".")
  end

  defp page_html(self_domain) do
    """
    <!doctype html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width,initial-scale=1">
    <title>sukhi-fedi — NodeInfo viewer</title>
    <style>
      :root { color-scheme: light dark; }
      body { font: 15px/1.5 system-ui, sans-serif; max-width: 640px; margin: 2rem auto; padding: 0 1rem; }
      h1 { font-size: 1.4rem; margin: 0 0 .25rem; }
      .sub { color: #888; margin: 0 0 1.5rem; font-size: .9rem; }
      form { display: flex; gap: .5rem; }
      input[type=text] { flex: 1; padding: .5rem .75rem; font: inherit; border: 1px solid #888; border-radius: 4px; }
      button { padding: .5rem 1rem; font: inherit; border: 0; border-radius: 4px; background: #2563eb; color: white; cursor: pointer; }
      button:disabled { opacity: .5; cursor: wait; }
      #result { margin-top: 1.5rem; }
      .card { border: 1px solid #8884; border-radius: 6px; padding: 1rem; }
      .row { display: flex; gap: 1rem; padding: .25rem 0; border-bottom: 1px solid #8882; }
      .row:last-child { border: 0; }
      .k { flex: 0 0 8rem; color: #888; }
      .v { flex: 1; word-break: break-word; font-family: ui-monospace, monospace; }
      .err { color: #c00; }
      details { margin-top: 1rem; }
      pre { background: #8881; padding: .75rem; border-radius: 4px; overflow: auto; font-size: 12px; }
      footer { margin-top: 3rem; color: #888; font-size: .85rem; }
      footer code { background: #8881; padding: 1px 4px; border-radius: 3px; }
      .bar { margin-top: .35rem; height: 6px; background: #8882; border-radius: 3px; overflow: hidden; }
      .bar > i { display: block; height: 100%; background: #2563eb; width: 0; transition: width .3s ease; }
      .bar > i.hot { background: #dc2626; }
      .dot { display: inline-block; width: 8px; height: 8px; border-radius: 50%; background: #888; vertical-align: middle; margin-right: .4rem; }
      .dot.live { background: #16a34a; }
      .dot.dead { background: #dc2626; }
    </style>
    </head>
    <body>
    <h1>NodeInfo viewer</h1>
    <p class="sub">Fetch any fediverse server's <code>/.well-known/nodeinfo</code> through #{self_domain}. Register a server to get a followable bot (<code>@watcher-&lt;domain&gt;@#{self_domain}</code>) that you can follow from any ActivityPub server.</p>

    <form id="f">
      <input type="text" id="domain" name="domain" placeholder="mastodon.social" autofocus required>
      <button type="submit">Fetch</button>
    </form>

    <div id="result"></div>

    <h2 style="font-size:1.1rem;margin-top:2.5rem">Currently watching</h2>
    <div id="watchers"><p class="sub">Loading…</p></div>

    <h2 style="font-size:1.1rem;margin-top:2.5rem">Host</h2>
    <p class="sub"><span id="stats-dot" class="dot"></span><span id="stats-status">connecting…</span> · 1 Hz · <code>:cpu_sup</code> / <code>:memsup</code></p>
    <div class="card">
      <div class="row">
        <div class="k">CPU</div>
        <div class="v"><span id="stats-cpu">—</span>%<div class="bar"><i id="stats-cpu-bar"></i></div></div>
      </div>
      <div class="row">
        <div class="k">Memory</div>
        <div class="v"><span id="stats-mem-used">—</span> / <span id="stats-mem-total">—</span> MiB<div class="bar"><i id="stats-mem-bar"></i></div></div>
      </div>
      <div class="row">
        <div class="k">Load avg</div>
        <div class="v"><span id="stats-l1">—</span> / <span id="stats-l5">—</span> / <span id="stats-l15">—</span> <span style="color:#888">(1/5/15 min)</span></div>
      </div>
    </div>

    <footer>
      Default bot: <code>@watcher@#{self_domain}</code>
    </footer>

    <script>
    const form = document.getElementById('f');
    const input = document.getElementById('domain');
    const out = document.getElementById('result');
    const list = document.getElementById('watchers');

    form.addEventListener('submit', async (e) => {
      e.preventDefault();
      const btn = form.querySelector('button');
      btn.disabled = true;
      out.innerHTML = '<p>Fetching…</p>';

      const domain = input.value.trim();
      try {
        const res = await fetch('/api/nodeinfo?domain=' + encodeURIComponent(domain));
        const json = await res.json();

        if (!res.ok) {
          out.innerHTML = `<div class="card err">Error: ${escapeHtml(json.error || res.statusText)}</div>`;
          return;
        }

        out.innerHTML = renderSnapshot(json) + renderRegisterBox(json.domain);
        wireRegister();
      } catch (err) {
        out.innerHTML = `<div class="card err">Network error: ${escapeHtml(err.message)}</div>`;
      } finally {
        btn.disabled = false;
      }
    });

    function renderSnapshot(s) {
      const rows = [
        ['Domain', s.domain],
        ['Software', s.software_name || '—'],
        ['Version', s.version || '—']
      ];
      const usage = s.raw && s.raw.usage || {};
      const users = usage.users || {};
      if (users.total != null) rows.push(['Total users', users.total]);
      if (users.activeMonth != null) rows.push(['MAU', users.activeMonth]);
      if (usage.localPosts != null) rows.push(['Local posts', usage.localPosts]);
      if (s.raw && s.raw.openRegistrations != null) rows.push(['Open regs', String(s.raw.openRegistrations)]);

      return '<div class="card">' +
        rows.map(([k, v]) =>
          `<div class="row"><div class="k">${escapeHtml(k)}</div><div class="v">${escapeHtml(String(v))}</div></div>`
        ).join('') +
        '</div>' +
        '<details><summary>Raw JSON</summary><pre>' + escapeHtml(JSON.stringify(s.raw, null, 2)) + '</pre></details>';
    }

    function renderRegisterBox(domain) {
      return `<div class="card" style="margin-top:1rem">
        <div>Register <strong>${escapeHtml(domain)}</strong> for monitoring — creates a followable bot.</div>
        <div style="margin-top:.5rem"><button id="reg" data-domain="${escapeHtml(domain)}">Register</button></div>
        <div id="reg-out" style="margin-top:.5rem"></div>
      </div>`;
    }

    function wireRegister() {
      const btn = document.getElementById('reg');
      if (!btn) return;
      btn.addEventListener('click', async () => {
        const dom = btn.dataset.domain;
        const regOut = document.getElementById('reg-out');
        btn.disabled = true;
        regOut.textContent = 'Registering…';
        try {
          const res = await fetch('/api/watchers', {
            method: 'POST',
            headers: { 'content-type': 'application/json' },
            body: JSON.stringify({ domain: dom })
          });
          const json = await res.json();
          if (!res.ok) {
            regOut.innerHTML = `<span class="err">${escapeHtml(json.error || res.statusText)}</span>`;
          } else {
            const msg = json.status === 'already_exists' ? 'Already registered' : 'Registered';
            regOut.innerHTML = `${escapeHtml(msg)} — follow <code>${escapeHtml(json.handle)}</code>`;
            loadWatchers();
          }
        } catch (err) {
          regOut.innerHTML = `<span class="err">${escapeHtml(err.message)}</span>`;
        } finally {
          btn.disabled = false;
        }
      });
    }

    async function loadWatchers() {
      try {
        const res = await fetch('/api/watchers');
        const json = await res.json();
        if (!json.watchers || !json.watchers.length) {
          list.innerHTML = '<p class="sub">Nobody is watched yet. Register a server above.</p>';
          return;
        }
        list.innerHTML = '<div class="card">' + json.watchers.map(w =>
          `<div class="row">
            <div class="k">${escapeHtml(w.monitored_domain)}</div>
            <div class="v"><code>${escapeHtml(w.handle)}</code></div>
          </div>`
        ).join('') + '</div>';
      } catch (err) {
        list.innerHTML = `<p class="err">${escapeHtml(err.message)}</p>`;
      }
    }

    function escapeHtml(s) {
      return String(s).replace(/[&<>"']/g, (c) => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
    }

    loadWatchers();

    // Host stats SSE — streams CPU, memory, load avg once per second.
    const mib = (b) => (b / 1048576).toFixed(0);
    const statsEs = new EventSource('/api/stats/stream');
    const statsDot = document.getElementById('stats-dot');
    const statsStatus = document.getElementById('stats-status');

    statsEs.onopen = () => { statsDot.className = 'dot live'; statsStatus.textContent = 'live'; };
    statsEs.onerror = () => { statsDot.className = 'dot dead'; statsStatus.textContent = 'disconnected — retrying'; };
    statsEs.onmessage = (e) => {
      const d = JSON.parse(e.data);
      document.getElementById('stats-cpu').textContent = d.cpu.toFixed(1);
      const cb = document.getElementById('stats-cpu-bar');
      cb.style.width = Math.min(100, d.cpu) + '%';
      cb.classList.toggle('hot', d.cpu > 80);

      const m = d.memory;
      document.getElementById('stats-mem-used').textContent = mib(m.used);
      document.getElementById('stats-mem-total').textContent = mib(m.total);
      const memPct = m.total > 0 ? (m.used / m.total) * 100 : 0;
      const mb = document.getElementById('stats-mem-bar');
      mb.style.width = memPct + '%';
      mb.classList.toggle('hot', memPct > 85);

      const fmt = (n) => (n == null ? '—' : n.toFixed(2));
      document.getElementById('stats-l1').textContent = fmt(d.load['1m']);
      document.getElementById('stats-l5').textContent = fmt(d.load['5m']);
      document.getElementById('stats-l15').textContent = fmt(d.load['15m']);
    };
    </script>
    </body>
    </html>
    """
  end
end
