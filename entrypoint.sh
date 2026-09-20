#!/usr/bin/env bash
# Railway entrypoint for timescale/timescaledb-ha.
#
# Runs as root, prepares everything PostgreSQL cannot prepare for itself on Railway,
# then hands over to the image's own entrypoint, which chowns $PGDATA and drops to the
# `postgres` user with gosu before the server starts.
set -Eeo pipefail

log() { printf '[railway] %s\n' "$*"; }

# ---------------------------------------------------------------------------
# 1. Scrub libpq client variables.
#
# `PGHOST`, `PGSSLMODE` and friends are read by every psql/pg_ctl call *inside* this
# container.  They are published on this service so other services can reference
# ${{TimescaleDB.PGHOST}}, which is a Railway-side substitution and unaffected by this.
# Left set, `pg_ctl -w start` would poll a TCP address that is not listening yet and the
# first-boot initialisation would hang.
# ---------------------------------------------------------------------------
unset PGHOST PGHOSTADDR PGUSER PGPASSWORD PGDATABASE PGSERVICE PGSERVICEFILE \
      PGSSLMODE PGSSLROOTCERT PGSSLCERT PGSSLKEY PGREQUIRESSL PGCONNECT_TIMEOUT PGPORT

PGROOT="${PGROOT:-/home/postgres}"
PGDATA="${PGDATA:-$PGROOT/pgdata/data}"
MOUNT="$(dirname "$PGDATA")"
SOCKET_DIR=/var/run/postgresql
STATE_DIR="$MOUNT/.railway"
CERT_DIR="$MOUNT/certs"

# ---------------------------------------------------------------------------
# 2. Volume ownership.
#
# Railway mounts the volume root-owned and the image runs as uid 1000.  Only the mount
# root needs fixing here: the image's own entrypoint chowns $PGDATA recursively, but it
# cannot create a directory inside a root-owned mount in the first place.
# ---------------------------------------------------------------------------
if [ "$(id -u)" -eq 0 ]; then
  install -d -o postgres -g postgres -m 0750 "$MOUNT" "$PGDATA" "$STATE_DIR" "$CERT_DIR" \
    "${BACKUPROOT:-$MOUNT/backup}"
  install -d -o postgres -g postgres -m 1777 "$SOCKET_DIR"
  # lost+found belongs to the filesystem, not to us; everything else under the mount
  # must be readable by postgres.
  chown postgres:postgres "$MOUNT" || true
fi

# ---------------------------------------------------------------------------
# 3. Size PostgreSQL from the cgroup.
#
# PostgreSQL derives nothing from the container's limits — it would run an 8 GB instance
# on the 128 MB stock shared_buffers.  These are passed as `-c` flags, which override
# postgresql.conf, so they re-tune themselves whenever the instance is resized.
# ---------------------------------------------------------------------------
read_mem_mb() {
  local v
  if [ -r /sys/fs/cgroup/memory.max ]; then v="$(cat /sys/fs/cgroup/memory.max)"; fi
  if [ -z "$v" ] || [ "$v" = max ]; then
    if [ -r /sys/fs/cgroup/memory/memory.limit_in_bytes ]; then
      v="$(cat /sys/fs/cgroup/memory/memory.limit_in_bytes)"
    fi
  fi
  case "$v" in ''|max|*[!0-9]*) v="" ;; esac
  # A cgroup with no limit reports a number close to the host's RAM; fall back to
  # MemTotal and let the operator override rather than tuning for 48 cores of host.
  if [ -z "$v" ] || [ "$v" -gt 1099511627776 ] 2>/dev/null; then
    v=$(( $(awk '/MemTotal/{print $2}' /proc/meminfo) * 1024 ))
  fi
  echo $(( v / 1024 / 1024 ))
}

read_cpus() {
  local q p
  if [ -r /sys/fs/cgroup/cpu.max ]; then
    read -r q p < /sys/fs/cgroup/cpu.max || true
    if [ "$q" != max ] && [ -n "$p" ] && [ "$p" -gt 0 ] 2>/dev/null; then
      echo $(( (q + p - 1) / p )); return
    fi
  fi
  if [ -r /sys/fs/cgroup/cpu/cpu.cfs_quota_us ] && [ -r /sys/fs/cgroup/cpu/cpu.cfs_period_us ]; then
    q="$(cat /sys/fs/cgroup/cpu/cpu.cfs_quota_us)"; p="$(cat /sys/fs/cgroup/cpu/cpu.cfs_period_us)"
    if [ "$q" -gt 0 ] 2>/dev/null && [ "$p" -gt 0 ] 2>/dev/null; then
      echo $(( (q + p - 1) / p )); return
    fi
  fi
  nproc
}

MEM_MB="${PG_MEMORY_MB:-$(read_mem_mb)}"
CPUS="${PG_CPUS:-$(read_cpus)}"
[ "$CPUS" -ge 1 ] 2>/dev/null || CPUS=1
[ "$MEM_MB" -ge 512 ] 2>/dev/null || MEM_MB=512

# The numbers below reproduce what `timescaledb-tune` writes, with one difference that
# matters here: the image only runs that tool once, inside initdb, so a resized instance
# keeps whatever its very first boot decided.  Recomputing them per boot means resizing
# the service is enough to re-tune the database.
MAX_CONNECTIONS="${PG_MAX_CONNECTIONS:-100}"
SHARED_BUFFERS=$(( MEM_MB * 25 / 100 )); [ "$SHARED_BUFFERS" -ge 128 ] || SHARED_BUFFERS=128
EFFECTIVE_CACHE=$(( MEM_MB * 75 / 100 ))
MAINT_WORK_MEM=$(( MEM_MB / 8 ))
[ "$MAINT_WORK_MEM" -le 2048 ] || MAINT_WORK_MEM=2048
[ "$MAINT_WORK_MEM" -ge 64 ] || MAINT_WORK_MEM=64
PARALLEL_WORKERS=$CPUS
PARALLEL_PER_GATHER=$(( CPUS / 2 )); [ "$PARALLEL_PER_GATHER" -ge 1 ] || PARALLEL_PER_GATHER=1
# every parallel worker in a gather gets its own work_mem, so the divisor counts them
WORK_MEM_KB=$(( (MEM_MB - SHARED_BUFFERS) * 1024 * 2 / (MAX_CONNECTIONS * (PARALLEL_PER_GATHER + 1) * 3) ))
[ "$WORK_MEM_KB" -ge 4096 ] || WORK_MEM_KB=4096
BG_WORKERS="${PG_TIMESCALEDB_BACKGROUND_WORKERS:-$(( CPUS * 2 ))}"
[ "$BG_WORKERS" -ge 8 ] || BG_WORKERS=8
WORKER_PROCESSES=$(( BG_WORKERS + PARALLEL_WORKERS + 3 ))
AUTOVACUUM_WORKERS=$(( CPUS + 2 )); [ "$AUTOVACUUM_WORKERS" -le 10 ] || AUTOVACUUM_WORKERS=10

# WAL lives on the volume, and the default volume is 5 GB, so size the WAL against the
# disk it actually has rather than against a fixed number.
VOLUME_MB="$(df -Pm "$MOUNT" 2>/dev/null | awk 'NR==2{print $2}')"
case "$VOLUME_MB" in ''|*[!0-9]*) VOLUME_MB=5120 ;; esac
MAX_WAL_MB=$(( VOLUME_MB * 20 / 100 ))
[ "$MAX_WAL_MB" -le 1024 ] || MAX_WAL_MB=1024
[ "$MAX_WAL_MB" -ge 256 ] || MAX_WAL_MB=256
MIN_WAL_MB=$(( MAX_WAL_MB / 2 ))

log "cgroup limits: ${MEM_MB} MB / ${CPUS} cpu(s); volume ${VOLUME_MB} MB"
log "shared_buffers=${SHARED_BUFFERS}MB effective_cache_size=${EFFECTIVE_CACHE}MB work_mem=${WORK_MEM_KB}kB maintenance_work_mem=${MAINT_WORK_MEM}MB timescaledb.max_background_workers=${BG_WORKERS} max_wal_size=${MAX_WAL_MB}MB"

# ---------------------------------------------------------------------------
# 4. TLS.
#
# The database is reachable from the internet through Railway's TCP proxy, which is a
# plain TCP passthrough, so without this every psql session crosses the internet in
# clear text.  The certificate is generated once and kept on the volume so it survives
# redeploys.  It is deliberately generated as a *leaf* (CA:FALSE): a self-signed CA in
# the server slot is rejected outright by strict clients such as Rust's rustls.
# ---------------------------------------------------------------------------
SSL_ARGS=()
if [ "${POSTGRES_SSL:-on}" = "on" ]; then
  if [ ! -s "$CERT_DIR/server.key" ] || [ ! -s "$CERT_DIR/server.crt" ]; then
    log "generating a self-signed server certificate in $CERT_DIR"
    openssl req -new -x509 -nodes -days 3650 -newkey rsa:2048 \
      -keyout "$CERT_DIR/server.key" -out "$CERT_DIR/server.crt" \
      -subj "/CN=${RAILWAY_PRIVATE_DOMAIN:-timescaledb.railway.internal}" \
      -addext "basicConstraints=critical,CA:FALSE" \
      -addext "keyUsage=critical,digitalSignature,keyEncipherment" \
      -addext "extendedKeyUsage=serverAuth" \
      -addext "subjectAltName=DNS:${RAILWAY_PRIVATE_DOMAIN:-timescaledb.railway.internal},DNS:${RAILWAY_TCP_PROXY_DOMAIN:-localhost},DNS:localhost" >/dev/null 2>&1
  fi
  chown postgres:postgres "$CERT_DIR/server.key" "$CERT_DIR/server.crt"
  chmod 0600 "$CERT_DIR/server.key"
  chmod 0644 "$CERT_DIR/server.crt"
  SSL_ARGS=(-c ssl=on -c "ssl_cert_file=$CERT_DIR/server.crt" -c "ssl_key_file=$CERT_DIR/server.key")
fi

# ---------------------------------------------------------------------------
# 5. Post-start bootstrap, in the background.
#
# It has to be in the background because the server it talks to is the one this script
# is about to exec.  Everything it does is idempotent and guarded by a marker on the
# volume, so an operator's later `ALTER ROLE` is not reverted on the next deploy.
# ---------------------------------------------------------------------------
APP_DB="${APP_DB:-tsdb}"
APP_USER="${APP_USER:-tsdbadmin}"
APP_PASSWORD="${APP_PASSWORD:-}"

bootstrap() {
  export PGPASSWORD="${POSTGRES_PASSWORD:-}"
  local psql=(psql -v ON_ERROR_STOP=1 -h "$SOCKET_DIR" -U postgres -d postgres --no-psqlrc -q)
  local i
  for i in $(seq 1 150); do
    pg_isready -h "$SOCKET_DIR" -U postgres -q && break
    sleep 2
  done
  if ! pg_isready -h "$SOCKET_DIR" -U postgres -q; then
    log "bootstrap: server did not become ready, skipping"
    return 0
  fi

  # 5a. Keep every database's TimescaleDB SQL version in step with the shared library.
  #     Without this the first image rebuild that ships a new TimescaleDB minor breaks
  #     every existing deployment with a version-mismatch error on connect.
  local db ext
  for db in $("${psql[@]}" -Atc "SELECT datname FROM pg_database WHERE datallowconn AND datname <> 'template0'"); do
    for ext in timescaledb timescaledb_toolkit; do
      local versions
      versions="$(psql -Atc "SELECT extversion FROM pg_extension WHERE extname = '$ext'" -h "$SOCKET_DIR" -U postgres -d "$db" --no-psqlrc 2>/dev/null || true)"
      [ -n "$versions" ] || continue
      local avail
      avail="$(psql -Atc "SELECT default_version FROM pg_available_extensions WHERE name = '$ext'" -h "$SOCKET_DIR" -U postgres -d "$db" --no-psqlrc 2>/dev/null || true)"
      if [ -n "$avail" ] && [ "$avail" != "$versions" ]; then
        log "bootstrap: $db: ALTER EXTENSION $ext UPDATE ($versions -> $avail)"
        psql -v ON_ERROR_STOP=1 -h "$SOCKET_DIR" -U postgres -d "$db" --no-psqlrc -q \
          -c "ALTER EXTENSION $ext UPDATE" || log "bootstrap: $db: $ext update failed"
      fi
    done
  done

  # 5b. Application role and database.
  #
  # The superuser is kept for administration; applications get a role that owns exactly
  # one database, the way Timescale Cloud hands out `tsdbadmin`.  A stranger deploying
  # this template gets least privilege without doing anything.
  if [ -z "$APP_PASSWORD" ]; then
    log "bootstrap: APP_PASSWORD is empty, skipping application role"
    return 0
  fi

  local marker
  marker="$STATE_DIR/approle-$(printf '%s:%s:%s' "$APP_USER" "$APP_DB" "$APP_PASSWORD" | sha256sum | cut -c1-32)"

  if [ -f "$marker" ]; then
    log "bootstrap: application role already provisioned for this user/password pair"
  else
    log "bootstrap: provisioning role $APP_USER and database $APP_DB"
    "${psql[@]}" \
      -v user="$APP_USER" -v pw="$APP_PASSWORD" <<'SQL'
SELECT format('CREATE ROLE %I LOGIN PASSWORD %L', :'user', :'pw')
 WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = :'user') \gexec
SELECT format('ALTER ROLE %I LOGIN PASSWORD %L', :'user', :'pw') \gexec
SQL
    "${psql[@]}" -v db="$APP_DB" -v user="$APP_USER" <<'SQL'
SELECT format('CREATE DATABASE %I OWNER %I', :'db', :'user')
 WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = :'db') \gexec
SQL
    psql -v ON_ERROR_STOP=1 -h "$SOCKET_DIR" -U postgres \
      -d "$APP_DB" --no-psqlrc -q -v user="$APP_USER" -v db="$APP_DB" <<'SQL'
CREATE EXTENSION IF NOT EXISTS timescaledb;
SELECT format('ALTER DATABASE %I OWNER TO %I', :'db', :'user') \gexec
SELECT format('ALTER SCHEMA public OWNER TO %I', :'user') \gexec
SELECT format('GRANT ALL ON SCHEMA public TO %I', :'user') \gexec
SQL
    # Nobody but the superuser has any business in the maintenance database.
    "${psql[@]}" \
      -c "REVOKE CONNECT ON DATABASE postgres FROM PUBLIC" || true
    : > "$marker"
    chown postgres:postgres "$marker" 2>/dev/null || true
    log "bootstrap: done"
  fi
}

if [ "${1:-postgres}" = postgres ]; then
  bootstrap &
fi

# ---------------------------------------------------------------------------
# 6. Hand over.
# ---------------------------------------------------------------------------
PG_ARGS=(
  -c "unix_socket_directories=$SOCKET_DIR"
  -c logging_collector=off
  -c "max_connections=$MAX_CONNECTIONS"
  -c "shared_buffers=${SHARED_BUFFERS}MB"
  -c "effective_cache_size=${EFFECTIVE_CACHE}MB"
  -c "maintenance_work_mem=${MAINT_WORK_MEM}MB"
  -c "work_mem=${WORK_MEM_KB}kB"
  -c "max_worker_processes=$WORKER_PROCESSES"
  -c "max_parallel_workers=$PARALLEL_WORKERS"
  -c "max_parallel_workers_per_gather=$PARALLEL_PER_GATHER"
  -c "max_parallel_maintenance_workers=$PARALLEL_PER_GATHER"
  -c "timescaledb.max_background_workers=$BG_WORKERS"
  -c "timescaledb.telemetry_level=${TIMESCALEDB_TELEMETRY:-off}"
  -c "autovacuum_max_workers=$AUTOVACUUM_WORKERS"
  -c "autovacuum_naptime=10"
  -c "wal_buffers=16MB"
  -c "min_wal_size=${MIN_WAL_MB}MB"
  -c "max_wal_size=${PG_MAX_WAL_SIZE:-${MAX_WAL_MB}MB}"
  -c "checkpoint_completion_target=0.9"
  -c "random_page_cost=1.1"
  -c "effective_io_concurrency=256"
  -c "default_statistics_target=100"
  -c "max_locks_per_transaction=128"
  -c "default_toast_compression=lz4"
  -c "jit=off"
  -c "log_timezone=UTC"
  -c "password_encryption=scram-sha-256"
  "${SSL_ARGS[@]}"
)

# shellcheck disable=SC2086
exec /docker-entrypoint.sh "$@" "${PG_ARGS[@]}" ${POSTGRES_EXTRA_ARGS:-}
