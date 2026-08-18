# pgvector 18 + pgAdmin

This runs Postgres 18 (with pgvector) and pgAdmin. The database data
directory can either be size-limited (a capped loopback filesystem, so it
can never fill up your server) or a plain host directory with no limit -
both setups below let you choose with `volume.conf`, and switch later
without losing data.

## Setup options

There are two ways to set this up, in two subfolders. Pick one and read
its `readme.txt`:

- **[`make-rsync-ssh/`](make-rsync-ssh/readme.txt)** - Run from your
  laptop. `deploy.sh` rsyncs the folder to your server over SSH and
  starts the stack there. Re-run it any time you change files — safe,
  only changed files are synced. Recommended.

- **[`manual/`](manual/readme.txt)** - Copy the folder onto the server
  yourself (scp, git clone, etc.) and run everything from there. No
  laptop-side tooling needed.

Both use the same `docker-compose.yml` services (postgres + pgadmin) and
the same capped/uncapped volume toggle (`volume.conf`); only how the
files get onto the server differs.

## Networking

- **Postgres <-> pgAdmin** - both services are in the same `docker-compose.yml` with no custom `networks:`, so Compose puts them on a shared default bridge network automatically. pgAdmin reaches Postgres at host `postgres`, port `5432`.

- **Outside apps <-> Postgres** - needs the host firewall / security group to allow inbound `5432`, restricted to trusted IPs. Postgres is bound to `0.0.0.0:5432`, so once that's open, apps can connect via psycopg using the server's IP and the credentials from `.env`. Same deal for pgAdmin's web UI on port `5050`. Use a strong `POSTGRES_PASSWORD` - it's the only thing gating access once the port is public.
