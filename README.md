# DI LUCCA local orchestration

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
