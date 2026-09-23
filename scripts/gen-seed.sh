#!/usr/bin/env bash
# gen-seed.sh — produce the root-DB seed artifacts this repo cannot ship.
#
# blocks-infra's docker-compose.yml expects BSON dumps (BlocksRootDb/ and
# BlocksConfiguration/) that are not in the repository. This script builds the
# minimum equivalent for a local instance: a root tenant, its JWT signing
# certificate, OIDC client registrations, identity providers, an identity
# configuration, an admin user, and the endpoint permission grants.
#
# It writes artifacts only — nothing touches the database. The compose service
# `blocks-seed` applies them on `up`.
#
# Produces:
#   certs/tenant.crt, certs/tenant.key   JWT signing pair (openssl)
#   certs/tenant.pfx                     PKCS#12, private — stored in Mongo
#   certs/tenant-public.pfx              PKCS#12, public only — primed into Redis
#   scripts/seed-rootdb.js               tenant, cert, clients, IdPs, config, user
#   scripts/seed-permissions.js          one grant per [ProtectedEndPoint]
#
# Values that must stay stable across runs (item id, tenant salt, certificate
# password, admin credentials) are generated once and persisted to .env. Change
# them there, not here — regenerating the salt invalidates the password hash.
#
# This does NOT generate the TLS certificate for nginx; that is mkcert's job:
#   mkcert "*.localtest.me" localtest.me
set -euo pipefail

_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
_env="$_root/.env"
[[ -f "$_env" ]] || { echo "gen-seed.sh: no .env at $_env" >&2; exit 1; }

command -v openssl  >/dev/null || { echo "gen-seed.sh: openssl not found" >&2; exit 1; }
command -v htpasswd >/dev/null || { echo "gen-seed.sh: htpasswd not found (apache2-utils)" >&2; exit 1; }
command -v python3  >/dev/null || { echo "gen-seed.sh: python3 not found" >&2; exit 1; }

set -a; source "$_env"; set +a

# _persist KEY VALUE — set KEY=VALUE in .env when missing or empty. Values that
# already carry a value are never overwritten, so re-running is safe.
_persist() {
  local key="$1" val="$2"
  if ! grep -qE "^${key}=" "$_env"; then
    printf '%s=%s\n' "$key" "$val" >> "$_env"
  elif grep -qE "^${key}=\\s*$" "$_env"; then
    # BSD and GNU sed disagree about -i; write through a temp file.
    sed "s|^${key}=.*|${key}=${val}|" "$_env" > "$_env.tmp" && mv "$_env.tmp" "$_env"
  fi
}

echo "==> generating stable identifiers (persisted to .env)"
_persist TENANT_ITEM_ID       "$(uuidgen | tr 'A-Z' 'a-z')"
_persist TENANT_SALT          "$(openssl rand -hex 16)"
_persist TENANT_CERT_PASSWORD "$(openssl rand -hex 16)"
_persist ADMIN_EMAIL          "admin@${DOMAIN}"
_persist ADMIN_PASSWORD       "$(openssl rand -base64 18 | tr -d '/+=' )"
# BCrypt cost. BCrypt.Net defaults to 11, but these images are amd64-only and run
# under qemu on Apple Silicon, where cost 11 takes ~80s per login attempt. 8 is
# ~8x cheaper and keeps a dev instance usable. Raise it for anything real —
# the stored hash carries its own cost, so verification needs no other change.
_persist BCRYPT_COST          "8"

# OIDC client credentials, one pair per service. run.sh generates these with a
# blk- prefix; configure.js relies on that prefix to tell platform registrations
# apart from project-level ones, so keep it.
for _svc in OS IAM DATA LOGIC LOCALIZATION STUDIO RELEASE MONITOR AGENTS UTILITIES; do
  _persist "${_svc}_CLIENT_ID"     "blk-$(openssl rand -hex 16)"
  _persist "${_svc}_CLIENT_SECRET" "$(openssl rand -hex 16)"
done

# Written into every tenant's DbConnectionString by configure.js. Derived from
# the Mongo credentials so it follows a changed MONGO_PASS.
_persist TENANT_DB_CONNECTION_STRING "mongodb://${MONGO_USER}:${MONGO_PASS}@mongodb:27017/?authSource=admin"
set -a; source "$_env"; set +a

: "${ROOT_TENANT_ID:?set ROOT_TENANT_ID in .env}"

mkdir -p "$_root/certs"

if [[ -f "$_root/certs/tenant.pfx" && "${FORCE_CERT_REGEN:-0}" != "1" ]]; then
  echo "==> JWT signing certificate exists, keeping it (FORCE_CERT_REGEN=1 to rotate)"
else
echo "==> JWT signing certificate (RSA-2048, SHA-256, 730 days)"
# Matches IdentifierConstants.KeyLength / AlgorithmName and the validity
# ProjectManagementService uses for a new project.
openssl req -x509 -newkey rsa:2048 -sha256 -days 730 -nodes \
  -keyout "$_root/certs/tenant.key" -out "$_root/certs/tenant.crt" \
  -subj "/CN=Selise-Blocks/O=SeliseBlocks" 2>/dev/null

openssl pkcs12 -export -out "$_root/certs/tenant.pfx" \
  -inkey "$_root/certs/tenant.key" -in "$_root/certs/tenant.crt" \
  -passout pass:"$TENANT_CERT_PASSWORD" 2>/dev/null

# Public-only PKCS#12: AuthenticationService reads this from Redis to validate
# bearer tokens. It must not carry the private key.
openssl pkcs12 -export -nokeys -out "$_root/certs/tenant-public.pfx" \
  -in "$_root/certs/tenant.crt" \
  -passout pass:"$TENANT_CERT_PASSWORD" 2>/dev/null

chmod 600 "$_root/certs/tenant.key" "$_root/certs/tenant.pfx"
fi

echo "==> CA bundle for service-to-service TLS"
# The services call each other over https://<svc>.${DOMAIN}, signed by mkcert's
# local CA, which no image trusts. SSL_CERT_FILE (set in the compose override)
# points at this bundle: the distro roots with the mkcert root appended, so
# public HTTPS keeps working too.
_caroot="$(mkcert -CAROOT 2>/dev/null)/rootCA.pem"
if [[ -f "$_caroot" ]]; then
  docker run --rm alpine:latest cat /etc/ssl/certs/ca-certificates.crt \
    > "$_root/certs/ca-bundle.crt" 2>/dev/null \
    || { echo "gen-seed.sh: could not read distro CA bundle from alpine" >&2; : > "$_root/certs/ca-bundle.crt"; }
  cat "$_caroot" >> "$_root/certs/ca-bundle.crt"
  echo "    $(grep -c 'BEGIN CERTIFICATE' "$_root/certs/ca-bundle.crt") certificates"
else
  echo "gen-seed.sh: no mkcert CA at $_caroot — run: mkcert -install" >&2
  exit 1
fi

echo "==> BCrypt hash for ${ADMIN_EMAIL} (cost ${BCRYPT_COST})"
# PasswordHasher.BuildPasswordMaterial: "<password>::<TenantSalt>".
# htpasswd emits $2y$; rewritten to $2a$, which BCrypt.Net accepts and which is
# byte-identical for ASCII input.
_material="${ADMIN_PASSWORD}::${TENANT_SALT}"
_hash="$(htpasswd -nbBC "${BCRYPT_COST}" u "$_material" | cut -d: -f2-)"
_hash="\$2a\$${_hash#*\$2y\$}"

echo "==> assembling seed scripts"
ADMIN_HASH="$_hash" python3 "$_root/scripts/_build_seed.py"

cat <<EOF

Done.

  admin      ${ADMIN_EMAIL}
  password   ${ADMIN_PASSWORD}       (also in .env)

Next:
  bash configure.sh
  docker compose up -d mongodb
  bash scripts/make-dumps.sh
  docker compose up -d
EOF
