pgvector 18 + pgAdmin  (deploy from laptop via SSH, capped/uncapped toggle)
============================================================================

This runs Postgres 18 (with pgvector) and pgAdmin. The database data
directory can either be size-limited (a capped loopback filesystem, so it
can never fill up your server) or a plain host directory with no limit.
You choose which with volume.conf, and you can switch later without
losing data.

Run deploy.sh from your laptop — it rsyncs this whole folder to the
server over SSH and starts the stack there. No manual copying needed.


WHAT EACH FILE DOES
-------------------
docker-compose.yml   the two services (postgres + pgadmin)
setup-volume.sh      creates/mounts the volume; capped or uncapped per
                            volume.conf, and switches between the two if you
                            already set one up before
check-mount.sh       stops startup if a capped volume is configured but
                            not actually mounted
up.sh                one command: set up the volume, then start
Makefile             same thing but with "make up" (optional)
.env.example         copy this to .env and put your passwords in
volume.conf.example  copy this to volume.conf to choose capped vs.
                            uncapped, and the size limit
deploy.sh            run FROM YOUR LAPTOP: syncs this folder (incl. your
                            local .env and volume.conf) to the server over SSH
                            and runs ./up.sh
deploy.conf.example  template for deploy.sh's target server settings
deploy.conf          your actual target (gitignored, per-machine — copy
                            it from deploy.conf.example)


DEPLOYING FROM YOUR LAPTOP
----------------------------
1. On your laptop, copy the env file and fill in your real passwords:
       cp .env.example .env

2. Copy the volume config and choose your mode:
       cp volume.conf.example volume.conf
       nano volume.conf
   Set CAPPED=true (default) for a size-limited volume — check free space
   on the server first (df -h /var/lib) and set CAP_SIZE to fit, with
   room left over for the system. Set CAPPED=false for no limit at all,
   using the plain host filesystem. Skipping this step is fine too —
   the server will fall back to CAPPED=true, CAP_SIZE=10G.

3. Point deploy.sh at your server:
       cp deploy.conf.example deploy.conf
       nano deploy.conf     # set REMOTE_HOST to a Host from ~/.ssh/config
   deploy.conf is gitignored, so each laptop/deployer can target a
   different server without touching any script.

4. Run:
       ./deploy.sh
   This rsyncs the stack (including .env and volume.conf) to
   REMOTE_BASE/STACK_NAME on the server and runs ./up.sh remotely. Needs
   rsync installed locally — deploy.sh will tell you how if it's missing.

   To deploy somewhere else just once, without editing deploy.conf:
       REMOTE_HOST=other-host ./deploy.sh
       ./deploy.sh --host=other-host --base=/opt/stacks --stack=pgvector-stack

5. Re-run ./deploy.sh any time you change files, .env, or volume.conf —
   it's safe to run repeatedly (only changed files are synced, existing
   DB data is never touched).


SWITCHING CAPPED <-> UNCAPPED LATER
-------------------------------------
Already deployed and want to change your mind? setup-volume.sh detects
what's currently live on the server and migrates it into the new mode
automatically — nothing is ever deleted, the old copy is always left on
disk as a backup so a bad switch is recoverable.

1. SSH into the server and stop the stack first:
       ssh <your-host>
       cd <REMOTE_BASE>/<STACK_NAME>
       sudo docker compose down          (or: make down)

2. Either edit volume.conf on the server directly, or edit it on your
   laptop and re-run ./deploy.sh to sync it over (the stack won't be
   restarted as part of a failed switch — see step 3).

3. Run the switch on the server:
       sudo ./setup-volume.sh            (or: make switch-capped / make switch-uncapped)
   It will describe what it's about to do and ask for confirmation
   before touching anything (pass -y to skip the prompt).

4. Start the stack again:
       ./up.sh   (or re-run ./deploy.sh from your laptop)

What gets left behind as a backup:
  - Switching capped -> uncapped: the old .img file is kept at
    /var/lib/pgvector18.img. Delete it yourself once you've verified
    the switch worked.
  - Switching uncapped -> capped: the old plain data directory is
    renamed to something like
    /var/lib/postgresql/18/data.pre-capped-<timestamp>. Delete it
    yourself once you've verified the switch worked.

You can also switch one-off without touching volume.conf:
       sudo ./setup-volume.sh --capped
       sudo ./setup-volume.sh --uncapped

Note: if you change volume.conf and just run ./deploy.sh without
stopping the stack first, setup-volume.sh will refuse to switch modes
while pgvector18 is running and up.sh will fail with a clear error —
stop the stack on the server, then re-run ./deploy.sh (or ./up.sh).


AFTER IT STARTS
---------------
pgAdmin runs at http://127.0.0.1:5050/pgadmin4  (server-local only).
To open it from your own computer, tunnel over SSH:
       ssh -L 5050:localhost:5050 user@your-server
then open http://localhost:5050/pgadmin4 in your browser.

Inside pgAdmin, add a new server with:
       Host: postgres
       Port: 5432
       Username / Password: the ones in your .env

Postgres itself is published on 0.0.0.0:5432, so other apps/servers can
connect directly (e.g. via psycopg) using the server's IP, port 5432,
and the POSTGRES_USER/POSTGRES_PASSWORD/POSTGRES_DB from your .env.
Lock this down at the firewall / security group level to trusted IPs
only — see IMPORTANT NOTES below.


EVERYDAY COMMANDS (run on the server, or over ssh)
----------------------------------------------------
Start:            ./up.sh
Stop (keep data): sudo docker compose down
See status:       sudo docker compose ps
See logs:         sudo docker compose logs -f
Back up the DB:   sudo docker exec pgvector18 pg_dump -U <user> <db> > backup.sql

(If you use make: make up / make down / make ps / make logs / make backup)


IMPORTANT NOTES
---------------
- Postgres port 5432 is exposed on all interfaces (0.0.0.0), not just
  localhost. Restrict it at the firewall / security group to only the
  IPs of apps that need it, and make sure POSTGRES_PASSWORD in .env is
  strong — it's your only line of defense once the port is public.

- CAPPED=true RESERVES space up front. A 10G limit needs 10G free
  right now. If setup-volume.sh says it can't allocate, lower CAP_SIZE.

- Your data is on a normal folder mount, so "docker compose down -v"
  does NOT delete it, in either mode.

- Don't let the database sit at 100% full. Postgres needs some free
  space to clean up after itself. Check now and then:
       df -h /var/lib/postgresql/18/data

- CAPPED=true already handles reboots safely: it writes an fstab line
  that mounts the storage BEFORE Docker starts, so Postgres never
  starts on an empty folder by mistake. check-mount.sh is that same
  safety net at stack-start time.

- Switching modes requires the stack to be stopped first — the script
  refuses to run while the pgvector18 container is up, to avoid
  migrating data out from under a live Postgres.

- Switching modes needs rsync installed on the server
  (apt-get install rsync on Debian/Ubuntu).


IF YOU NEED A BIGGER LIMIT LATER (staying capped)
----------------------------------------------------
       sudo docker compose down
       sudo umount /var/lib/postgresql/18/data
       sudo fallocate -l 20G /var/lib/pgvector18.img
       sudo e2fsck -f /var/lib/pgvector18.img
       sudo resize2fs /var/lib/pgvector18.img
       sudo mount -a
       ./up.sh
