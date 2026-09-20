# TimescaleDB on Railway
#
# The published image already contains everything the database needs — TimescaleDB,
# Toolkit, pgvector/pgvectorscale, PostGIS, pgBackRest.  What it does not contain is a
# boot-time step, and Railway needs three of them:
#
#   1. the volume is mounted root-owned, and the image runs as `postgres` (uid 1000),
#   2. PostgreSQL sizes nothing from the cgroup, so it would start with 128 MB of
#      shared_buffers on an 8 GB instance,
#   3. a floating `pg18` tag moves the TimescaleDB shared library under a database whose
#      SQL extension is still on the older version, which is a hard error until someone
#      runs `ALTER EXTENSION timescaledb UPDATE`.
#
# One entrypoint layer on top of the release image covers all three and keeps the tag
# floating within the PostgreSQL major.
ARG TIMESCALEDB_IMAGE=timescale/timescaledb-ha:pg18
FROM ${TIMESCALEDB_IMAGE}

# root is required so the entrypoint can chown the mounted volume; it drops back to the
# `postgres` user through the image's own entrypoint (`gosu postgres`) before the server
# is ever started.
USER root

COPY entrypoint.sh /railway-entrypoint.sh
RUN chmod 0755 /railway-entrypoint.sh

EXPOSE 5433

ENTRYPOINT ["/railway-entrypoint.sh"]
CMD ["postgres"]
