#!/bin/sh
# Empty the write-test tables in the cluster's Postgres and reset the id sequences.
# Run after a write load test to reset state. Needs kubectl (k3s installs a symlink).
#
# Covers BOTH table families, because the cluster hosts two write paths:
#   notes / notes_history              — scribe + scribe-bun (the Bun stack)
#   bench_notes / bench_notes_history  — spring-notes + fastapi-notes (cross-runtime peers)
# Each family is truncated only if present, so this is a no-op on a Bun-only cluster and
# doesn't need the peers deployed. Both members of a family are truncated in ONE statement
# because the history table carries an ON DELETE CASCADE foreign key — truncating the
# parent alone would error.
set -e
export KUBECONFIG=${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}

PSQL="kubectl -n flight-scribe exec -i postgres-0 -- psql -U scribe -d scribe"

count() {
  $PSQL -tAc "select count(*) from $1;" 2>/dev/null | tr -d '[:space:]' || true
}

before_notes=$(count notes)
before_bench=$(count bench_notes)
echo "==> rows before:  notes=${before_notes:-(none)}  bench_notes=${before_bench:-(none)}"

# to_regclass() returns NULL for a missing table, so each block is skipped cleanly when
# that stack isn't deployed.
$PSQL -q -c "
DO \$\$
BEGIN
  IF to_regclass('public.notes') IS NOT NULL THEN
    TRUNCATE TABLE notes, notes_history RESTART IDENTITY;
  END IF;
  IF to_regclass('public.bench_notes') IS NOT NULL THEN
    TRUNCATE TABLE bench_notes, bench_notes_history RESTART IDENTITY;
  END IF;
END
\$\$;"

echo "==> rows after:   notes=$(count notes)  bench_notes=$(count bench_notes)"
