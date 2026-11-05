# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Web.SetupController do
  @moduledoc false

  import Plug.Conn

  @config_path "/etc/sukhi/instance.json"

  def home(conn, _opts) do
    conn
    |> put_resp_content_type("text/html; charset=utf-8")
    |> send_resp(200, page_html())
  end

  defp page_html do
    """
    <!doctype html>
    <html lang="en">
      <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>sukhi-fedi setup</title>
        <style>
          :root { color-scheme: light dark; font: 16px system-ui, sans-serif; }
          body { max-width: 46rem; margin: 3rem auto; padding: 0 1.25rem; line-height: 1.55; }
          code, pre { background: #8882; border-radius: .35rem; padding: .15rem .35rem; }
          pre { overflow-x: auto; padding: 1rem; }
          h1 { line-height: 1.2; }
        </style>
      </head>
      <body>
        <h1>Frontend setup required</h1>
        <p>sukhi-fedi is running, but no frontend route is configured yet.</p>
        <h2>1. Configure a frontend</h2>
        <p>Edit <code>#{@config_path}</code> and add at least one frontend route.
        This file is non-secret; keep passwords and tokens in environment variables
        or Podman secrets.</p>
        <pre>{
      "site_name": "sukhi-fedi",
      "frontends": {
        "web-next": { "url": "http://web-next:3000" }
      },
      "routes": [
        { "pattern": "/**", "frontend": "web-next" }
      ]
    }</pre>
        <h2>2. Create the first admin</h2>
        <p>Run this on the host while the gateway image is available. Replace the
        placeholders; do not put a real password in this page or in a config file.</p>
        <pre>podman exec -it &lt;gateway-container&gt; \
    /app/bin/combined eval \
    'SukhiFedi.Release.create_admin("admin-name", "use-a-long-passphrase")'</pre>
        <p>Then sign in at <code>/login</code> and open <code>/admin</code>.
        Register a passkey after the first login.</p>
        <h2>3. Bring an existing Datalevin store</h2>
        <p>Stop the old instance before copying its data. Restore the complete
        <code>DATALEVIN_DIR</code>, including <code>graph/</code> when graph mode
        was enabled. Restore <code>SUKHI_QUEUE_DB</code> and
        <code>DELIVERY_QUEUE_DB</code> too; SQLite raw blobs may be stored in the
        queue database. If raw or media storage uses S3, restore those buckets
        and their prefixes as well.</p>
        <pre>podman stop &lt;old-gateway-container&gt;
    # restore the saved files under /var/lib/sukhi
    # mount the saved instance config at /etc/sukhi/instance.json
    podman start &lt;gateway-container&gt;</pre>
        <p>Use the same image/release family and keep <code>DOMAIN</code> and
        signing secrets stable. This restores an existing store; it does not
        convert Postgres data into Datalevin. Check the journal for
        <code>datalevin_init_complete</code> before treating the restore as ready.</p>
        <p>Before a planned backup, create a non-secret inventory with:</p>
        <pre>podman exec &lt;gateway-container&gt; \
    /app/bin/combined eval \
    'SukhiFedi.Release.write_datalevin_backup_manifest!()'</pre>
        <p>After restoring the files, validate the inventory before normal
        startup:</p>
        <pre>podman exec &lt;gateway-container&gt; \
    /app/bin/combined eval \
    'SukhiFedi.Release.check_datalevin_backup_manifest!()'</pre>
        <p>After updating the mounted config, restart the gateway and check its
        journal for the resolved frontend and route diagnostics.</p>
      </body>
    </html>
    """
  end
end
