# DI LUCCA local orchestration

## Fresh local installation

The new `compose.fresh.yaml` combines runtime generation, PostgreSQL and
MongoDB migrations, IAM provisioning, and application builds. It uses a
separate Compose project (`dlc-fresh`) and `.local/` for generated local
credentials. The initial administrator email defaults to
`admin@dilucca.local`; `DLC_ADMIN_EMAIL` can override it. The generated
password is stored in `.local/secrets/staff-password.txt`. Mail is captured
by Mailpit at port 18025 by default; this setup does not send real email.

To use an authenticated SMTP relay for the worker, set the non-secret
`DLC_WORKER_SMTP_HOST`, `DLC_WORKER_SMTP_PORT`, `DLC_WORKER_SMTP_STARTTLS`,
`DLC_WORKER_SMTP_USERNAME`, and `DLC_WORKER_SMTP_FROM` values in the ignored
`.env` file. Put the password in the ignored
`.local/secrets/worker/smtp-password` file, readable by the worker container,
then recreate the worker with
`docker compose -f compose.fresh.yaml up -d --no-deps --force-recreate dlc-worker`.
This configures delivery. Immediate appointment email requires the worker's
scheduled-event consumer; reminders also require the appointment scheduler.

With Docker Desktop running and the repositories checked out in the expected
domain directories, run from this repository:

```powershell
docker compose -f compose.fresh.yaml up -d --build
```

Ports 8081 and 18025 must be available. An existing deployment on those ports
must be stopped first; its volumes are separate and are not deleted. On first
startup Compose generates local credentials, builds the images, initializes
the databases, runs the migrations and starts the services. The first build
and startup can take several minutes. Use the current `develop` versions of
the domain repositories, including the Patients API and portal.

The fresh installation was verified from empty volumes, including all service
processes, portal entry points, administrator login and authenticated Patients,
Appointments and Billing requests. This does not replace a complete clinical
and payment end-to-end test. The existing restart workflow below is unchanged.

## Stages: develop, qa and main

Each stage is a separate Compose project (`dlc-develop`, `dlc-qa`, `dlc-main`) with its own
PostgreSQL, MongoDB, ports, subnet, image tag and generated secrets under
`.local/stages/<stage>` (ignored by Git). No database port is published.

| Stage | Code | Liquibase context | Seed | Front | Mailpit | DB viewer |
|---|---|---|---|---|---|---|
| develop | repositories next to this one (`develop`) | `dev` | yes | 8081 | 18025 | 127.0.0.1:18091 |
| qa | worktrees of each `qa` branch in `<root>/.stages/qa` | `qa` | yes | 8082 | 18026 | 127.0.0.1:18092 |
| main | none until the first release (databases only) | `prod` | never | - | - | 127.0.0.1:18093 |

`-Mode full` starts databases, APIs, portals and front; `-Mode db` (default) only the
databases and the viewer. Billing is not started in qa because its qa branch holds no code yet.

Every domain repository runs its own migrations with that context, so changesets marked
`dev or qa` are skipped in `main`. MongoDB requires TLS 1.2+ in the three stages
(`compose.stage-tls.yaml`); `stage-db.ps1` creates a per-stage CA and server certificate.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\stage-db.ps1 -Stage develop -Mode full
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\stage-db.ps1 -Stage qa -Mode full
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\stage-db.ps1 -Stage main
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\stage-db.ps1 -Stage qa -Mode full -Action status
```

`down` removes only that stage's containers and volumes. The administrator of each stage is
`admin@dilucca.local` with the password in `.local/stages/<stage>/secrets/staff-password.txt`.
In the viewer, use server `dlc-postgres`, database `di_lucca`, user `postgres` and the password
in `secrets/pg.txt` of the stage. These stages run locally; hosting of shared stages remains pending.

## Existing local installation

This repository starts the existing local DI LUCCA installation, including MongoDB, PostgreSQL, RabbitMQ, IAM, Patients, Appointments, Clinical, Billing, the gateway, portals and worker. It preserves the existing database volumes.

From this directory in PowerShell 5.1 or later, run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\up.ps1
```

Open <http://localhost:8081>. Local test email is captured by Mailpit at <http://localhost:18025>; it is not delivered to external inboxes. The command uses two Compose projects because MongoDB has its own infrastructure repository. Running `docker compose up -d` alone here does not start MongoDB or select the external configuration.

To validate configuration and prerequisites without restarting services:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\up.ps1 -Validate
```

## Prerequisites and scope

- Docker Desktop must be running and able to mount the private runtime directory.
- Place this repository at `dlc-infra/dlc-infra` under the project root. MongoDB infrastructure and the database migration repositories must be in their normal domain directories under that root.
- This command restarts an **already provisioned local installation**. It requires existing `dlc-e2e_pg_data`, `dlc-e2e-mongo_mongo_data` and `dlc-e2e-mongo_mongo_config` volumes, the `clinical-data-e2e` network, migrations and local `:e2e` images. It checks these requirements and will not silently create empty databases.
- It uses the existing images without rebuilding them or pulling source changes. The code in an image may differ from a repository's current branch. Building images, first-time key generation and database provisioning/migration are not yet automated by this command.
- Configuration and secrets are outside this Git repository, by default in `%USERPROFILE%\DLC\infra-local`. A different location can be selected with `DLC_RUNTIME_DIR`. Do not commit secrets or include them in issues.

The private runtime directory must contain `stack.env`, `auth-config.json`, `registry/`, `svc/`, `secrets/` and `mongo-secrets/` from the provisioned installation. The Compose files refer to those files through `DLC_RUNTIME_DIR`; they do not contain credentials.

The script validates configuration and local image availability, verifies MongoDB health, starts both projects and checks that services are running and the front and IAM JWKS respond. Startup is not a substitute for a full clinical or payment end-to-end test.
