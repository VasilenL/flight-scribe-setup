#!/bin/sh
# Empty the notes tables in the cluster's Postgres and reset the id sequence.
# Run after a write load test to reset state. Needs kubectl (k3s installs a symlink).
set -e
export KUBECONFIG=${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}

PSQL="kubectl -n flight-scribe exec -i postgres-0 -- psql -U scribe -d scribe"

echo "==> rows before: $($PSQL -tAc 'select count(*) from notes;' 2>/dev/null || echo '(no notes table)')"
$PSQL -c 'TRUNCATE TABLE notes, notes_history RESTART IDENTITY;'
echo "==> rows after:  $($PSQL -tAc 'select count(*) from notes;' 2>/dev/null || echo '?')"
