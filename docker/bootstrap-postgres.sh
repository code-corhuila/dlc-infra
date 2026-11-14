#!/bin/sh
# Run once against a fresh local database after PostgreSQL is ready.
set -eu

: "${PGHOST:?PGHOST is required}"
: "${PGDATABASE:?PGDATABASE is required}"
: "${PGUSER:?PGUSER is required}"
: "${PGPASSWORD_FILE:?PGPASSWORD_FILE is required}"
: "${DLC_SECRETS_DIR:?DLC_SECRETS_DIR is required}"
: "${DLC_BOOTSTRAP_DIR:?DLC_BOOTSTRAP_DIR is required}"

export PGPASSWORD="$(cat "$PGPASSWORD_FILE")"
psql -X -v ON_ERROR_STOP=1 -q <<'SQL'
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION IF NOT EXISTS pg_trgm;
SQL

for domain in iam patients appointments billing notifications; do
  # A stage branch may not contain every domain yet (for example Billing before
  # its promotion to qa); that domain's schema and roles are then not created.
  if [ ! -f "$DLC_BOOTSTRAP_DIR/$domain.sql" ]; then
    echo "Skipping $domain: no bootstrap.sql in this stage"
    continue
  fi
  psql -X -v ON_ERROR_STOP=1 -q -f "$DLC_BOOTSTRAP_DIR/$domain.sql"
done

while IFS='|' read -r role file; do
  exists=$(psql -X -At -v role="$role" <<'SQL'
SELECT count(*) FROM pg_roles WHERE rolname = :'role';
SQL
)
  [ "$exists" = 1 ] || continue
  password=$(cat "$DLC_SECRETS_DIR/$file")
  # Passing the password through psql's literal quoting avoids SQL injection.
  psql -X -v ON_ERROR_STOP=1 -q -v role="$role" -v password="$password" <<'SQL'
ALTER ROLE :"role" PASSWORD :'password';
SQL
done <<'ROLES'
iam_migrator|iam-migrator-password.txt
iam_runtime|iam-runtime.txt
patients_migrator|patients-migrator.txt
patients_app|patients-db/password
appointments_migrator|appointments-migrator.txt
appointments_runtime|appointments-runtime.txt
billing_migrator|billing-migrator.txt
billing_runtime|billing-runtime.txt
notifications_migrator|notifications-migrator.txt
notifications_runtime|notifications-runtime.txt
ROLES
