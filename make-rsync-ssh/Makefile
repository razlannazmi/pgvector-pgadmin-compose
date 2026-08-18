# Wrapper so `make up` performs the volume setup before starting the stack.
# Compose has no native pre-up hook, so this Makefile is that hook.

.PHONY: up down stop logs ps setup check restart backup switch-capped switch-uncapped

## up: ensure the volume (capped or uncapped, per volume.conf) is ready, verify, then start the stack
up: setup check
	sudo docker compose up -d
	@echo ""
	@echo "Stack is up. pgAdmin: http://127.0.0.1:5050/pgadmin4  (localhost only)"

## setup: create/mount the volume in whichever mode volume.conf says (idempotent, needs sudo)
setup:
	sudo ./setup-volume.sh

## check: refuse to continue if a capped volume is configured but not mounted
check:
	sudo ./check-mount.sh

## switch-capped: switch to a size-capped loopback volume, migrating any live data in (stop the stack first)
switch-capped:
	sudo ./setup-volume.sh --capped

## switch-uncapped: switch to the plain host filesystem, migrating any live data out (stop the stack first)
switch-uncapped:
	sudo ./setup-volume.sh --uncapped

## down: stop and remove containers + network (KEEPS all data)
down:
	sudo docker compose down

## stop: stop containers without removing them
stop:
	sudo docker compose stop

## restart: restart the running containers
restart:
	sudo docker compose restart

## logs: follow logs for all services
logs:
	sudo docker compose logs -f

## ps: show container status
ps:
	sudo docker compose ps

## backup: dump the database to ./backups/ with a timestamp
backup:
	@mkdir -p backups
	@set -a; . ./.env; set +a; \
	 sudo docker exec pgvector18 pg_dump -U "$$POSTGRES_USER" "$$POSTGRES_DB" \
	   > "backups/$$POSTGRES_DB-$$(date +%Y%m%d-%H%M%S).sql" && \
	 echo "Backup written to backups/"
