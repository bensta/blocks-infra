# Running Blocks locally

`docker-compose.yml` is upstream's, unmodified. Everything here is layered on top
through `docker-compose.override.yml`, which Compose merges automatically — so the
upstream file can be updated from the remote without conflicts.

Once set up:

```bash
docker compose up -d
```

No profile flags: `COMPOSE_PROFILES` in `.env` selects them.

---

## Why setup is needed at all

`docker-compose.yml` expects two BSON dumps, `BlocksRootDb/` and
`BlocksConfiguration/`, restored by its `mongodb-seed` service. **They are not in
the repository** — not on any branch, not in a release. `DumpDb.sh` exists to
*produce* them from a populated instance, so upstream's assumption is that a
colleague sends you a copy.

That matters because the platform cannot bootstrap itself from an empty database:

- `blocks-iam` is its own identity provider and signs tokens with a per-tenant
  X.509 certificate held in `BlocksRootDb.Tenants`.
- Only `blocks-os` creates tenants and generates those certificates, during
  project provisioning.
- `blocks-os` reads its own configuration out of `BlocksRootDb` before it starts.

Neither side can go first. The dump is the way in.

**If you can get the real dumps, use them** — drop them in as `BlocksRootDb/` and
`BlocksConfiguration/` and skip to [Run](#run). They carry fifteen template
collections this setup cannot reconstruct.

Otherwise `scripts/gen-seed.sh` + `scripts/make-dumps.sh` build a minimal
equivalent from the public service repositories.

---

## First-time setup

### 1. Prerequisites

```bash
brew install mkcert nss     # locally-trusted TLS
mkcert -install             # needs your admin password; run in a real terminal
```

`openssl`, `htpasswd` and `python3` are also used, all present on macOS.

### 2. Configuration

```bash
cp .env.example .env
```

Set `MONGO_PASS` and `RABBITMQ_PASS` — they are baked into the volumes on first
start. `DOMAIN` defaults to `localtest.me`, a public domain whose every subdomain
resolves to `127.0.0.1`; nothing to install, and unlike `localhost` it gives real
subdomains and a shared cookie domain, which the tenant model needs.

```bash
bash scripts/resolve-tags.sh    # pin image tags; no `latest` exists upstream
```

Check what it picked. It takes the newest tag carrying an amd64 image, and the
registry contains the occasional junk push.

### 3. TLS certificate

```bash
mkcert "*.localtest.me" localtest.me
mv _wildcard.localtest.me+1.pem     certs/localtest.me.crt
mv _wildcard.localtest.me+1-key.pem certs/localtest.me.key
```

### 4. Seed artifacts

```bash
bash scripts/gen-seed.sh    # certificate, password hash, seed scripts, CA bundle
bash configure.sh           # upstream's generator -> configure.js
```

`gen-seed.sh` writes the generated admin password and tenant identifiers into
`.env` and reuses them on later runs, so re-running is safe.

### 5. Build the dumps

```bash
docker compose up -d mongodb
bash scripts/make-dumps.sh
```

This applies the seed scripts to a running database and exports the result to the
paths `mongodb-seed` mounts.

### 6. Run

```bash
docker compose up -d
```

Sign in at `https://os.localtest.me` with `ADMIN_EMAIL` / `ADMIN_PASSWORD` from
`.env`.

---

## What the override adds

| | |
| --- | --- |
| `mongodb` healthcheck | upstream's has spaces inside one `--eval` argument; podman-compose word-splits the `CMD` array, so mongosh gets only `db.runCommand({` and the container never turns healthy |
| `DOTNET_EnableWriteXorExecute=0` | images are amd64-only; under qemu, .NET's W^X JIT handling corrupts dynamically generated reflection stubs and the MongoDB driver crashes the process |
| `SSL_CERT_FILE` + `certs/ca-bundle.crt` | services call each other over `https://<svc>.${DOMAIN}`, signed by a CA no image trusts |
| `cert-cache-seed` | `AuthenticationService` reads the tenant's public certificate from Redis with no fallback; on a miss every bearer token fails with `Certificate not found`. `blocks-os` normally writes it while provisioning a project |
| `local-edge` | `acme-companion` cannot issue for a domain nobody owns, so nginx serves the locally-signed wildcard. Its network aliases matter: `*.localtest.me` resolves to `127.0.0.1`, which *inside a container* is that container itself, so server-to-server calls would never leave it |

---

## Known limits

**Four images are not published.** `blocksos/blocks-{studio,agents}-{api,worker}`
return 404 on Docker Hub. One 404 fails the whole `up`, so `COMPOSE_PROFILES`
selects upstream's per-service profiles rather than `apps`.

**The full stack does not fit on a 4-core/4GB VM.** Each emulated .NET service
takes ~430MB; sixteen need ~6.9GB. Starting them all made the podman VM
unresponsive and corrupted container state. `COMPOSE_PROFILES` is set to
`infra,local-edge,os,iam`. Add services one at a time, or:

```bash
podman machine stop && podman machine set -m 8192 && podman machine start
```

**`BlocksConfiguration` has one of sixteen collections.** Only `Permissions` is
reconstructed, so projects created through the console get working authorization
but no roles, email templates or localization. This needs the upstream dump.

**Permissions are a stand-in.** `scripts/permissions.txt` lists every
`[ProtectedEndPoint]` name harvested from the public repositories, all granted to
`admin`. The real template presumably models several roles.

**`BCRYPT_COST` defaults to 8**, below BCrypt.Net's 11. Fine for a disposable
local instance; raise it for anything else.

**The first login after starting `iam-api` takes ~80s**, then ~1.5s. Unexplained;
the leading suspect is the audit event published to `blocks_user_activity_listener`
on a cold RabbitMQ connection, which logs `NO_ROUTE` when no worker consumes it.

---

## Scripts

| | |
| --- | --- |
| `scripts/gen-seed.sh` | certificate, BCrypt hash, CA bundle, seed scripts; persists stable values to `.env` |
| `scripts/make-dumps.sh` | applies the seed and exports the BSON dumps |
| `scripts/resolve-tags.sh` | pins `<SVC>_TAG` to the newest amd64 tag |
| `scripts/permissions.txt` | protected resource names, with the grep that re-harvests them |
| `scripts/_build_seed.py` | assembles the seed from `.env` (called by `gen-seed.sh`) |

`.env`, `certs/`, the generated seed scripts and both dumps are gitignored: they
hold private keys, client secrets and a password hash.
