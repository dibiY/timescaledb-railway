# timescaledb-railway

TimescaleDB on [Railway](https://railway.com), built as a single entrypoint layer on top
of the official `timescale/timescaledb-ha` release image.

The published image already ships TimescaleDB, TimescaleDB Toolkit, pgvector,
pgvectorscale, PostGIS and pgBackRest. This repo exists for the three things it cannot
do for itself on Railway:

| Gap | What the entrypoint does |
|---|---|
| The volume is mounted root-owned and the image runs as uid 1000 | chowns the mount root as root, then hands over to the image's own entrypoint, which drops to `postgres` with `gosu` |
| PostgreSQL sizes nothing from the cgroup — an 8 GB instance would run on 128 MB of `shared_buffers` | reads `memory.max` / `cpu.max` and passes `shared_buffers`, `effective_cache_size`, `work_mem`, `maintenance_work_mem`, the parallel-worker set and `timescaledb.max_background_workers` as `-c` flags, which override `postgresql.conf` and re-tune on a resize |
| A floating `pg18` tag moves the TimescaleDB shared library out from under a database whose SQL extension is a version behind | runs `ALTER EXTENSION timescaledb UPDATE` (and the same for `timescaledb_toolkit`) in every database, once per boot, only when the versions actually differ |

It also generates a self-signed **leaf** certificate on the volume and starts the server
with `ssl=on`, because Railway's TCP proxy is a plain passthrough and the database is
reachable from the internet through it. The certificate is a leaf, not a self-signed CA,
so strict TLS clients accept it as a server certificate.

Finally it provisions an application role that owns exactly one database — the same
shape Timescale Cloud hands out as `tsdbadmin` — so nothing has to connect as the
superuser. That step is guarded by a marker on the volume keyed to the user/password
pair, so a password an operator changes by hand is not reverted on the next deploy.

## Variables

| Variable | Default | Purpose |
|---|---|---|
| `POSTGRES_PASSWORD` | — (required) | superuser password |
| `APP_USER` | `tsdbadmin` | application role; owns `APP_DB` |
| `APP_PASSWORD` | — | application role password. Unset: the role is not created |
| `APP_DB` | `tsdb` | application database, created owned by `APP_USER` |
| `TIMESCALEDB_TELEMETRY` | `off` | `off` or `basic` |
| `POSTGRES_SSL` | `on` | set `off` to serve plaintext only |
| `PG_MAX_CONNECTIONS` | `100` | |
| `PG_MEMORY_MB` / `PG_CPUS` | cgroup | override the detected limits |
| `PG_TIMESCALEDB_BACKGROUND_WORKERS` | `2 x cpus`, min 8 | |
| `PG_MAX_WAL_SIZE` | 20% of the volume, capped at `1GB` | raise only alongside a larger volume |
| `POSTGRES_EXTRA_ARGS` | — | extra `-c key=value` flags, appended last |

`TIMESCALEDB_IMAGE` is a build argument, so the PostgreSQL major can be moved without
touching the entrypoint.

## Volume

Mount at `/home/postgres/pgdata`. `PGDATA` is `/home/postgres/pgdata/data`, one level
below the mount root — the cluster cannot sit at the mount root itself, and the
certificate, the pgBackRest root and the bootstrap markers are siblings of it.
