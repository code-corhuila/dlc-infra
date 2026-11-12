#!/bin/sh
set -eu
: "${PGHOST:?PGHOST is required}"
: "${PGDATABASE:?PGDATABASE is required}"
: "${PGUSER:?PGUSER is required}"
: "${PGPASSWORD_FILE:?PGPASSWORD_FILE is required}"
: "${DLC_SECRETS_DIR:?DLC_SECRETS_DIR is required}"
: "${DLC_ADMIN_EMAIL:?DLC_ADMIN_EMAIL is required}"
export PGPASSWORD="$(cat "$PGPASSWORD_FILE")"

while IFS='|' read -r client dir; do
  secret=$(cat "$DLC_SECRETS_DIR/$dir/client-secret")
  psql -X -q -v ON_ERROR_STOP=1 -v client="$client" -v secret="$secret" <<'SQL'
INSERT INTO iam.service_clients(client_id,status) VALUES (:'client','ACTIVE') ON CONFLICT(client_id) DO NOTHING;
INSERT INTO iam.service_client_secrets(client_id,slot,secret_hash) VALUES (:'client',1,crypt(:'secret',gen_salt('bf',12))) ON CONFLICT(client_id,slot) DO NOTHING;
SELECT 1 / (EXISTS (SELECT 1 FROM iam.service_client_secrets WHERE client_id=:'client' AND slot=1 AND secret_hash=crypt(:'secret',secret_hash)))::int;
SQL
done <<'CLIENTS'
clinical-api|cln
patients-api|patients-iam
appointments-api|apt
billing-api|billing
dlc-worker|worker
CLIENTS

while IFS='|' read -r client audience scope; do
  psql -X -q -v ON_ERROR_STOP=1 -v client="$client" -v audience="$audience" -v scope="$scope" <<'SQL'
INSERT INTO iam.service_client_grants(client_id,audience,scope) VALUES (:'client',:'audience',:'scope') ON CONFLICT DO NOTHING;
SQL
done <<'GRANTS'
clinical-api|auth-service|identity:validate
clinical-api|patients-api|patients:validate
clinical-api|appointments-api|assignments:read
clinical-api|appointments-api|appointments:encounter-status:read
clinical-api|appointments-api|patient-gates:coordinate
clinical-api|billing-api|billing:encounter-freeze:write
patients-api|auth-service|identity:validate
patients-api|appointments-api|assignments:read
patients-api|appointments-api|patient-gates:coordinate
appointments-api|auth-service|identity:validate
appointments-api|patients-api|patients:validate
billing-api|auth-service|identity:validate
billing-api|appointments-api|appointments:encounter-status:read
billing-api|appointments-api|assignments:read
billing-api|patients-api|patients:billing-contact:read
dlc-worker|patients-api|patients:billing-contact:read
dlc-worker|billing-api|billing:notification-summary:read
dlc-worker|billing-api|billing:invoice-pdf:read
dlc-worker|appointments-api|appointments:notification-details:read
dlc-worker|appointments-api|appointments:notification-outcome:write
GRANTS

password=$(cat "$DLC_SECRETS_DIR/staff-password.txt")
psql -X -q -v ON_ERROR_STOP=1 -v email="$DLC_ADMIN_EMAIL" -v password="$password" <<'SQL'
WITH created AS (
INSERT INTO iam.users(user_id,email,password_hash,status,email_verified_at,created_at,updated_at,display_name)
VALUES (gen_random_uuid(),:'email',crypt(:'password',gen_salt('bf',12)),'ACTIVE',now(),now(),now(),'Administrador local')
ON CONFLICT(email) DO NOTHING RETURNING user_id
)
INSERT INTO iam.user_roles(user_id,role,assigned_at)
SELECT user_id,'ADMINISTRATOR',now() FROM created ON CONFLICT DO NOTHING;
SELECT 1 / (EXISTS (SELECT 1 FROM iam.users u JOIN iam.user_roles r USING (user_id) WHERE u.email=:'email' AND r.role='ADMINISTRATOR'))::int;
-- Repair an administrator created by an older local initializer only when
-- the generated credential matches; never change an unrelated account.
UPDATE iam.users u SET display_name='Administrador local', updated_at=now()
WHERE u.email=:'email' AND u.display_name IS NULL AND u.password_hash=crypt(:'password',u.password_hash)
  AND EXISTS (SELECT 1 FROM iam.user_roles r WHERE r.user_id=u.user_id AND r.role='ADMINISTRATOR');
SQL
