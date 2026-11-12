"""Generate local-only credentials into an empty private runtime directory."""
import base64
import json
import os
from pathlib import Path
import secrets
import shutil
import subprocess

root = Path(os.environ.get("DLC_RUNTIME_DIR", "/runtime"))
root.mkdir(parents=True, exist_ok=True)
marker = root / ".initialized"
if marker.is_file():
    required = (
        "stack.env", "auth-config.json", "registry/portal-registry.json", "svc/jwks.json",
        "secrets/iam.env", "secrets/pg.txt", "secrets/iam-migrator-password.txt",
        "secrets/iam-runtime.txt", "secrets/patients-migrator.txt", "secrets/patients-db/password",
        "secrets/appointments-migrator.txt", "secrets/appointments-runtime.txt",
        "secrets/billing-migrator.txt", "secrets/billing-runtime.txt", "secrets/notifications-migrator.txt", "secrets/notifications-runtime.txt",
        "secrets/staff-password.txt", "secrets/cln/clinical-runtime-password",
        "mongo-secrets/mongo-root-password.txt", "mongo-secrets/mongo-keyfile",
        "mongo-secrets/clinical-migrator-password.txt", "mongo-secrets/clinical-runtime-password.txt",
        "mongo-secrets/clinical-backup-password.txt", "launcher", "secrets/iam-runtime/runtime.env",
        "secrets/rabbitmq/runtime.env", "secrets/apt/runtime.env", "secrets/billing/runtime.env",
        "secrets/cln/runtime.env", "secrets/worker/runtime.env",
    )
    if any(not (root / name).is_file() for name in required):
        raise SystemExit("The existing runtime is incomplete; credentials were not changed.")
    print("Local runtime already initialized; existing credentials were preserved.")
    raise SystemExit(0)
if any(root.iterdir()):
    # Compose may create empty directory placeholders for file bind mounts
    # while creating the dependent containers. Only remove the exact known
    # placeholders; never replace an existing file or an unknown directory.
    allowed = {
        "secrets", "secrets/iam-migrator-password.txt", "secrets/patients-migrator.txt",
        "secrets/appointments-migrator.txt", "secrets/billing-migrator.txt",
        "secrets/notifications-migrator.txt", "mongo-secrets",
        "mongo-secrets/mongo-root-password.txt", "mongo-secrets/mongo-keyfile",
        "mongo-secrets/clinical-migrator-password.txt", "mongo-secrets/clinical-runtime-password.txt",
        "mongo-secrets/clinical-backup-password.txt", "launcher", "auth-config.json", "registry", "svc",
        "secrets/iam-runtime", "secrets/rabbitmq", "secrets/patients-apt", "secrets/apt", "secrets/billing",
        "secrets/cln", "secrets/patients-iam", "secrets/patients-db", "secrets/pat-int", "secrets/worker",
    }
    entries = list(root.rglob("*"))
    if any(p.is_symlink() or not p.is_dir() or p.relative_to(root).as_posix() not in allowed for p in entries):
        raise SystemExit("Runtime directory is not empty; refusing to overwrite existing configuration.")
    for path in sorted(entries, key=lambda p: len(p.parts), reverse=True):
        path.rmdir()
root.chmod(0o700)
shutil.copyfile("/usr/local/bin/dlc-launcher", root / "launcher")
(root / "launcher").chmod(0o755)

def write(path, value):
    target = root / path
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(value, encoding="utf-8")
    target.chmod(0o600)

def allow_service_read(path):
    # Only use on a file mounted into the service that owns it. The parent
    # runtime directory stays private to the host; bind mounts are scoped.
    (root / path).chmod(0o644)

def token():
    return secrets.token_hex(32)

def base64_key():
    return base64.b64encode(secrets.token_bytes(32)).decode("ascii")

passwords = {name: token() for name in (
    "pg", "iam-migrator", "iam-runtime", "patients-migrator", "patients-runtime",
    "appointments-migrator", "appointments-runtime", "billing-migrator",
    "billing-runtime", "notifications-migrator", "notifications-runtime", "rabbitmq", "admin",
    "mongo-root", "mongo-keyfile", "clinical-migrator", "clinical-runtime", "clinical-backup",
)}
for name, filename in {
    "pg": "pg.txt", "iam-migrator": "iam-migrator-password.txt", "iam-runtime": "iam-runtime.txt",
    "patients-migrator": "patients-migrator.txt", "patients-runtime": "patients-db/password",
    "appointments-migrator": "appointments-migrator.txt", "appointments-runtime": "appointments-runtime.txt",
    "billing-migrator": "billing-migrator.txt", "billing-runtime": "billing-runtime.txt",
    "notifications-migrator": "notifications-migrator.txt", "notifications-runtime": "notifications-runtime.txt", "admin": "staff-password.txt",
}.items():
    write("secrets/" + filename, passwords[name])
    if name not in ("pg", "iam-runtime", "admin"):
        allow_service_read("secrets/" + filename)
for name in ("mongo-root", "mongo-keyfile", "clinical-migrator", "clinical-runtime", "clinical-backup"):
    filename = name if name == "mongo-keyfile" else name + "-password.txt"
    write("mongo-secrets/" + filename, passwords[name])
    if name in ("mongo-root", "clinical-migrator"):
        allow_service_read("mongo-secrets/" + filename)
write("secrets/cln/clinical-runtime-password", passwords["clinical-runtime"])
allow_service_read("secrets/cln/clinical-runtime-password")
for domain in ("apt", "billing", "cln", "patients-iam", "worker"):
    write("secrets/" + domain + "/client-secret", token())
    allow_service_read("secrets/" + domain + "/client-secret")

for key in ("jwt", "svc"):
    private = root / "secrets" / (key + ".key")
    public = root / "secrets" / (key + ".pub")
    subprocess.run(["openssl", "genpkey", "-quiet", "-algorithm", "RSA", "-pkeyopt", "rsa_keygen_bits:3072", "-out", str(private)], check=True)
    subprocess.run(["openssl", "pkey", "-in", str(private), "-pubout", "-out", str(public)], check=True)
    private.chmod(0o600)
    public.chmod(0o644)
for source, target in (("jwt.pub", "apt/staff.pub"), ("jwt.pub", "cln/staff.pub"),
                       ("svc.pub", "apt/service.pub"), ("svc.pub", "pat-int/service-public.pem"),
                       ("svc.pub", "billing/service-public.pem")):
    write("secrets/" + target, (root / "secrets" / source).read_text())
    allow_service_read("secrets/" + target)

modulus = subprocess.check_output(["openssl", "rsa", "-pubin", "-in", str(root / "secrets/svc.pub"), "-modulus", "-noout"], text=True).strip().split("=", 1)[1]
encode = lambda b: base64.urlsafe_b64encode(b).rstrip(b"=").decode("ascii")
write("svc/jwks.json", json.dumps({"keys": [{"kty": "RSA", "use": "sig", "alg": "RS256", "kid": "svc-dev-1", "n": encode(bytes.fromhex(modulus)), "e": encode(bytes.fromhex("010001"))}]}))
write("secrets/billing/rabbitmq-uri", "amqp://e2e:" + passwords["rabbitmq"] + "@rabbitmq:5672")
allow_service_read("secrets/billing/rabbitmq-uri")
for directory, values in {
    "rabbitmq": {"RABBITMQ_DEFAULT_PASS": passwords["rabbitmq"]},
    "apt": {"DB_PASSWORD": passwords["appointments-runtime"], "APPOINTMENTS_RABBITMQ_URI": "amqp://e2e:" + passwords["rabbitmq"] + "@rabbitmq:5672"},
    "billing": {"SPRING_DATASOURCE_PASSWORD": passwords["billing-runtime"]},
    "worker": {"DB_PASSWORD": passwords["notifications-runtime"], "WORKER_RABBITMQ_URI": "amqp://e2e:" + passwords["rabbitmq"] + "@rabbitmq:5672"},
    "cln": {"RABBITMQ_URL": "amqp://e2e:" + passwords["rabbitmq"] + "@rabbitmq:5672/"},
}.items():
    path = "secrets/" + directory + "/runtime.env"
    write(path, "".join(k + "=" + v + "\n" for k, v in values.items()))
    allow_service_read(path)
(root / "secrets/patients-apt").mkdir(parents=True, exist_ok=True)
write("stack.env", "\n".join(("RMQ_PASS=" + passwords["rabbitmq"], "APT_DB_PASSWORD=" + passwords["appointments-runtime"], "BILLING_DB_PASSWORD=" + passwords["billing-runtime"], "NOTIFICATIONS_DB_PASSWORD=" + passwords["notifications-runtime"])) + "\n")
pem = lambda name: (root / "secrets" / name).read_text().strip().replace("\n", "\\n")
iam = {
    "IAM_DATABASE_URL": "jdbc:postgresql://dlc-postgres:5432/di_lucca", "IAM_DATABASE_USER": "iam_runtime", "IAM_DATABASE_PASSWORD": passwords["iam-runtime"],
    "IAM_JWT_KID": "staff-dev-1", "IAM_JWT_ISSUER": "https://iam.dev.dlc.test", "IAM_JWT_AUDIENCE": "dlc-api",
    "IAM_JWT_PRIVATE_KEY_PEM": pem("jwt.key"), "IAM_JWT_PUBLIC_KEY_PEM": pem("jwt.pub"),
    "IAM_SERVICE_JWT_KID": "svc-dev-1", "IAM_SERVICE_JWT_PRIVATE_KEY_PEM": pem("svc.key"), "IAM_SERVICE_JWT_PUBLIC_KEY_PEM": pem("svc.pub"),
    "IAM_INTERNAL_SERVICE_ISSUER": "https://services.dev.dlc.test", "IAM_INTERNAL_SERVICE_AUDIENCE": "auth-service", "IAM_INTERNAL_SERVICE_JWKS_URI": "http://svc-jwks/jwks.json",
    "IAM_AUTH_ALLOWED_ORIGIN": "http://localhost:8081", "IAM_TRUSTED_GATEWAY_IP": "172.30.0.241",
    "IAM_RABBITMQ_HOST": "rabbitmq", "IAM_RABBITMQ_PORT": "5672", "IAM_RABBITMQ_USER": "e2e", "IAM_RABBITMQ_PASSWORD": passwords["rabbitmq"], "IAM_OUTBOX_EXCHANGE": "dlc.events",
    "IAM_EMAIL_SMTP_HOST": "mailpit", "IAM_EMAIL_SMTP_PORT": "1025", "IAM_EMAIL_SMTP_STARTTLS": "false", "IAM_EMAIL_SMTP_SSL": "false", "IAM_EMAIL_SMTP_USER": "local", "IAM_EMAIL_SMTP_PASSWORD": "local", "IAM_EMAIL_FROM": "iam@dilucca.test",
}
for name in ("IAM_CSRF_KEY_BASE64", "IAM_LOGIN_IP_DIGEST_KEY_BASE64", "IAM_REGISTRATION_PROOF_KEY_BASE64", "IAM_IDENTITY_EMAIL_LIMIT_KEY_BASE64"):
    iam[name] = base64_key()
write("secrets/iam.env", "".join(key + "=" + value + "\n" for key, value in iam.items()))
write("secrets/iam-runtime/runtime.env", "".join(key + "=" + value + "\n" for key, value in iam.items()))
allow_service_read("secrets/iam-runtime/runtime.env")
write("auth-config.json", json.dumps({"issuer": "https://iam.dev.dlc.test", "audience": "dlc-api"}))
registry = Path("/input/portal-registry.json")
if not registry.is_file():
    raise SystemExit("Missing portal registry from dlc-front; the runtime is incomplete.")
registry_data = json.loads(registry.read_text(encoding="utf-8"))
billing_package = Path("/input/billing-package.json")
if not billing_package.is_file():
    raise SystemExit("Missing billing portal package metadata; the runtime is incomplete.")
billing_release = json.loads(billing_package.read_text(encoding="utf-8"))["version"]
for portal in registry_data["portals"]:
    if portal["portalId"] == "billing":
        old_release = portal["release"]
        portal["release"] = billing_release
        portal["entryUrl"] = portal["entryUrl"].replace("/" + old_release + "/", "/" + billing_release + "/")
write("registry/portal-registry.json", json.dumps(registry_data, ensure_ascii=False))
write(".initialized", "local development runtime v1\n")
print("Local runtime created. Test email is captured in Mailpit.")
