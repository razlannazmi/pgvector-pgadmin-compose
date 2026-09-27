# pgvector 18 + pgAdmin stack

This runs Postgres 18 (with pgvector) and pgAdmin. The database data
directory can either be size-limited (a capped loopback filesystem, so it
can never fill up your server) or a plain host directory with no limit.
You choose which with `volume.conf`, and you can switch later without
losing data.

There are two ways to get this folder onto the server. Both run the same
stack; pick whichever suits you:

- **[Option A: deploy from your laptop](#option-a-deploy-from-your-laptop)**
  (recommended) - `deploy.sh` rsyncs this folder to the server over SSH
  and starts the stack there.
- **[Option B: manual](#option-b-manual)** - copy the folder onto the
  server yourself (scp, git clone, etc.) and run everything there.

## What each file does

| File | Purpose |
| --- | --- |
| `docker-compose.yml` | the two services (postgres + pgadmin) |
| `setup-volume.sh` | creates/mounts the volume; capped or uncapped per `volume.conf`, and switches between the two if you already set one up before |
| `check-mount.sh` | stops startup if a capped volume is configured but not actually mounted |
| `up.sh` | one command: set up the volume, then start |
| `Makefile` | same thing but with `make up` (optional) |
| `.env.example` | copy this to `.env` and put your passwords in |
| `volume.conf.example` | copy this to `volume.conf` to choose capped vs. uncapped, and the size limit |
| `deploy.sh` | *Option A only, runs on your laptop:* syncs this folder (incl. your local `.env` and `volume.conf`) to the server over SSH and runs `./up.sh` |
| `deploy.conf.example` | *Option A only:* template for `deploy.sh`'s target server settings |
| `deploy.conf` | *Option A only:* your actual target (gitignored, per-machine - copy it from `deploy.conf.example`) |

## Configure

Do this wherever you'll run from: on your laptop for Option A, on the
server for Option B.

1. Copy the env file and fill in your real passwords:

   ```sh
   cp .env.example .env
   nano .env
   ```

2. Copy the volume config and choose your mode:

   ```sh
   cp volume.conf.example volume.conf
   nano volume.conf
   ```

   Set `CAPPED=true` (default) for a size-limited volume - check free
   space on the server first (`df -h /var/lib`) and set `CAP_SIZE` to
   fit, with room left over for the system. Set `CAPPED=false` for no
   limit at all, using the plain host filesystem. Skipping this step is
   fine too - the server will fall back to `CAPPED=true`, `CAP_SIZE=10G`.

## Option A: deploy from your laptop

1. Point `deploy.sh` at your server:

   ```sh
   cp deploy.conf.example deploy.conf
   nano deploy.conf     # set REMOTE_HOST to a Host from ~/.ssh/config
   ```

   `deploy.conf` is gitignored, so each laptop/deployer can target a
   different server without touching any script.

2. Run:

   ```sh
   ./deploy.sh
   ```

   This rsyncs the stack (including `.env` and `volume.conf`) to
   `REMOTE_BASE/STACK_NAME` on the server and runs `./up.sh` remotely.
   Needs rsync installed locally - `deploy.sh` will tell you how if it's
   missing.

   To deploy somewhere else just once, without editing `deploy.conf`:

   ```sh
   REMOTE_HOST=other-host ./deploy.sh
   ./deploy.sh --host=other-host --base=/opt/stacks --stack=pgvector-stack
   ```

3. Re-run `./deploy.sh` any time you change files, `.env`, or
   `volume.conf` - it's safe to run repeatedly (only changed files are
   synced, existing DB data is never touched).

## Option B: manual

1. Copy this folder to the server, then go in:

   ```sh
   cd stack
   ```

2. Make the scripts runnable (needed if the bits were lost on copy):

   ```sh
   chmod +x up.sh setup-volume.sh check-mount.sh
   ```

3. Do the [Configure](#configure) steps above, on the server.

4. Start everything:

   ```sh
   ./up.sh
   ```

   (or, if you have `make` installed: `make up`)

`deploy.sh` and `deploy.conf.example` aren't needed on the server - you
can leave them out when copying.

## Switching capped <-> uncapped later

Already running and want to change your mind? `setup-volume.sh` detects
what's currently live on the server and migrates it into the new mode
automatically - nothing is ever deleted, the old copy is always left on
disk as a backup so a bad switch is recoverable.

All of these run **on the server** (for Option A, first
`ssh <your-host>` and `cd <REMOTE_BASE>/<STACK_NAME>`).

1. Stop the stack first:

   ```sh
   sudo docker compose down          # or: make down
   ```

2. Flip `CAPPED` in `volume.conf`. Either edit it on the server
   directly, or (Option A) edit it on your laptop and re-run
   `./deploy.sh` to sync it over - the stack won't start while the mode
   switch is pending, see the note below.

3. Run the switch:

   ```sh
   sudo ./setup-volume.sh            # or: make switch-capped / make switch-uncapped
   ```

   It will describe what it's about to do and ask for confirmation
   before touching anything (pass `-y` to skip the prompt).

4. Start the stack again:

   ```sh
   ./up.sh                           # or, Option A: re-run ./deploy.sh from your laptop
   ```

What gets left behind as a backup:

- **Capped -> uncapped:** the old `.img` file is kept at
  `/var/lib/pgvector18.img`. Delete it yourself once you've verified the
  switch worked.
- **Uncapped -> capped:** the old plain data directory is renamed to
  something like `/var/lib/postgresql/18/data.pre-capped-<timestamp>`.
  If an old `/var/lib/pgvector18.img` was still there from an earlier
  capped setup, it is never overwritten: it's renamed to
  `/var/lib/pgvector18.img.pre-capped-<timestamp>` and a fresh image is
  created (so you need `CAP_SIZE` of extra free disk). Delete the
  backups yourself once you've verified the switch worked.

If the server rebooted and the capped image simply failed to mount,
`./up.sh` just mounts it again; it does not treat the empty directory as
a switch.

You can also switch one-off without touching `volume.conf`:

```sh
sudo ./setup-volume.sh --capped
sudo ./setup-volume.sh --uncapped
```

> **Note:** if you change `volume.conf` and just run `./deploy.sh` (or
> `./up.sh`) without stopping the stack first, `setup-volume.sh` will
> refuse to switch modes while `pgvector18` is running and `up.sh` will
> fail with a clear error - stop the stack on the server, then re-run.

## After it starts

pgAdmin runs at <http://127.0.0.1:5050/pgadmin4> (server-local only). To
open it from your own computer, tunnel over SSH:

```sh
ssh -L 5050:localhost:5050 user@your-server
```

then open <http://localhost:5050/pgadmin4> in your browser.

Alternatively, put a reverse proxy (e.g. httpd) on the server that
forwards `/pgadmin4` to `http://127.0.0.1:5050/pgadmin4`. Anything the
proxy listens on is public, so give it TLS and an IP allowlist or extra
auth.

Inside pgAdmin, add a new server with:

- **Host:** `postgres`
- **Port:** `5432`
- **Username / Password:** the ones in your `.env`

Postgres itself is published on `0.0.0.0:5432`, so other apps/servers
can connect directly (e.g. via psycopg) using the server's IP, port
5432, and the `POSTGRES_USER` / `POSTGRES_PASSWORD` / `POSTGRES_DB` from
your `.env`. Lock this down at the firewall / security group level to
trusted IPs only - see [Important notes](#important-notes) below.

## Everyday commands

Run on the server (or over ssh):

| Task | Command |
| --- | --- |
| Start | `./up.sh` |
| Stop (keep data) | `sudo docker compose down` |
| See status | `sudo docker compose ps` |
| See logs | `sudo docker compose logs -f` |
| Back up the DB | `sudo docker exec pgvector18 pg_dump -U <user> <db> > backup.sql` |

(If you use make: `make up` / `make down` / `make ps` / `make logs` /
`make backup`)

## Important notes

- Postgres port 5432 is exposed on all interfaces (`0.0.0.0`), not just
  localhost. Restrict it at the firewall / security group to only the
  IPs of apps that need it, and make sure `POSTGRES_PASSWORD` in `.env`
  is strong - it's your only line of defense once the port is public.

- `CAPPED=true` **reserves** space up front. A 10G limit needs 10G free
  right now. If `setup-volume.sh` says it can't allocate, lower
  `CAP_SIZE`.

- Your data is on a normal folder mount, so `docker compose down -v`
  does **not** delete it, in either mode.

- Don't let the database sit at 100% full. Postgres needs some free
  space to clean up after itself. Check now and then:

  ```sh
  df -h /var/lib/postgresql/18/data
  ```

- `CAPPED=true` already handles reboots safely: it writes an fstab line
  that mounts the storage **before** Docker starts, so Postgres never
  starts on an empty folder by mistake. `check-mount.sh` is that same
  safety net at stack-start time.

- Switching modes requires the stack to be stopped first - the script
  refuses to run while the `pgvector18` container is up, to avoid
  migrating data out from under a live Postgres.

- Switching modes needs rsync installed on the server
  (`apt-get install rsync` on Debian/Ubuntu).

## If you need a bigger limit later (staying capped)

```sh
sudo docker compose down
sudo umount /var/lib/postgresql/18/data
sudo fallocate -l 20G /var/lib/pgvector18.img
sudo e2fsck -f /var/lib/pgvector18.img
sudo resize2fs /var/lib/pgvector18.img
sudo mount -a
./up.sh
```
