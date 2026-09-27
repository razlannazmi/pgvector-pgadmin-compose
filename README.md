# pgvector 18 + pgAdmin

This runs Postgres 18 (with pgvector) and pgAdmin. The database data
directory can either be size-limited (a capped loopback filesystem, so it
can never fill up your server) or a plain host directory with no limit.
You choose with `volume.conf`, and can switch later without losing data.

## Setup

Everything lives in [`stack/`](stack/). See [`stack/README.md`](stack/README.md)
for the full setup. There are two ways to get it onto the server:

- **Deploy from your laptop** (recommended) - `stack/deploy.sh` rsyncs
  the folder to your server over SSH and starts the stack there. Re-run
  it any time you change files — safe, only changed files are synced.

- **Manual** - copy `stack/` onto the server yourself (scp, git clone,
  etc.) and run `./up.sh` there. No laptop-side tooling needed.

Both run the same `docker-compose.yml` services (postgres + pgadmin) and
the same capped/uncapped volume toggle; only how the files get onto the
server differs.

## Networking

- **Postgres <-> pgAdmin** - both services are in the same `docker-compose.yml` with no custom `networks:`, so Compose puts them on a shared default bridge network automatically. pgAdmin reaches Postgres at host `postgres`, port `5432`.

- **Outside apps <-> Postgres** - needs the host firewall / security group to allow inbound `5432`, restricted to trusted IPs. Postgres is bound to `0.0.0.0:5432`, so once that's open, apps can connect via psycopg using the server's IP and the credentials from `.env`. Use a strong `POSTGRES_PASSWORD` - it's the only thing gating access once the port is public.

- **Outside <-> pgAdmin** - pgAdmin's web UI is bound to `127.0.0.1:5050`, so it is *not* reachable at `<server-ip>:5050`. Reach it through an SSH tunnel (`ssh -L 5050:localhost:5050 <host>`) or a reverse proxy on the same host (e.g. httpd proxying `/pgadmin4` to `http://127.0.0.1:5050/pgadmin4`). If you add a proxy, whatever it listens on is public, so put TLS and an IP allowlist or extra auth on it.
