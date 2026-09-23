#!/usr/bin/env bash
# make-dumps.sh — build the BSON dumps that docker-compose.yml's mongodb-seed
# expects, from the seed scripts scripts/gen-seed.sh produced.
#
# The repository does not ship BlocksRootDb/ and BlocksConfiguration/. Upstream's
# workflow is that someone exports them from a populated instance with DumpDb.sh.
# Without access to one, this recreates the equivalent locally:
#
#   1. apply seed-rootdb.js + seed-permissions.js + configure.js to BlocksRootDb
#   2. copy the endpoint permission grants into BlocksConfiguration, which is the
#      template database blocks-os copies into every new project
#   3. mongodump both into the paths mongodb-seed mounts
#
# Run once after gen-seed.sh. Afterwards `docker compose up -d` seeds itself
# through upstream's own mongodb-seed service, with no custom steps.
#
#   bash scripts/gen-seed.sh
#   bash configure.sh
#   docker compose up -d mongodb        # just the database
#   bash scripts/make-dumps.sh
#   docker compose up -d
set -euo pipefail

_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ -f "$_root/.env" ]] || { echo "make-dumps.sh: no .env" >&2; exit 1; }
set -a; source "$_root/.env"; set +a

ROOT_DB="${BlocksSecret__RootDatabaseName:-BlocksRootDb}"
URI="mongodb://${MONGO_USER}:${MONGO_PASS}@localhost:27017/?authSource=admin"

for f in scripts/seed-rootdb.js scripts/seed-permissions.js configure.js; do
  [[ -f "$_root/$f" ]] || { echo "make-dumps.sh: missing $f — run gen-seed.sh and configure.sh first" >&2; exit 1; }
done

docker inspect mongodb --format '{{.State.Status}}' 2>/dev/null | grep -q running \
  || { echo "make-dumps.sh: mongodb is not running (docker compose up -d mongodb)" >&2; exit 1; }

echo "==> applying seed scripts to ${ROOT_DB}"
for f in seed-rootdb.js seed-permissions.js; do
  docker cp "$_root/scripts/$f" "mongodb:/tmp/$f" >/dev/null
  docker exec mongodb mongosh --quiet "${URI%/?*}/${ROOT_DB}?authSource=admin" --file "/tmp/$f"
done
docker cp "$_root/configure.js" mongodb:/tmp/configure.js >/dev/null
docker exec mongodb mongosh --quiet "${URI%/?*}/${ROOT_DB}?authSource=admin" --file /tmp/configure.js >/dev/null
echo "    configure.js applied"

echo "==> seeding BlocksConfiguration (template database for new projects)"
# Only Permissions so far. The real BlocksConfiguration carries sixteen
# collections — Roles, EmailTemplates, localization and the rest — which are not
# reconstructible from the public source and need the upstream dump.
docker exec mongodb mongosh --quiet "$URI" --eval '
  const src = db.getSiblingDB("'"$ROOT_DB"'");
  const dst = db.getSiblingDB("BlocksConfiguration");
  dst.Permissions.deleteMany({});
  const docs = src.Permissions.find({}).toArray();
  if (docs.length) dst.Permissions.insertMany(docs);
  print("    Permissions: " + dst.Permissions.countDocuments({}));
'

# Projects created through the console leave tenants behind whose own databases
# are not part of this dump — in a fresh install they appear as projects that
# cannot be opened. Drop them so the seed is a clean root-tenant baseline.
# KEEP_PROJECTS=1 keeps them.
if [[ "${KEEP_PROJECTS:-0}" != "1" ]]; then
  echo "==> removing non-root tenants from the seed"
  docker exec mongodb mongosh --quiet "${URI%/?*}/${ROOT_DB}?authSource=admin" --eval '
    const root = db.Tenants.findOne({ IsRootTenant: true });
    const stale = db.Tenants.find({ IsRootTenant: { $ne: true } }, { TenantId: 1, Name: 1 }).toArray();
    stale.forEach(t => print("    dropping tenant " + t.Name + " (" + t.TenantId + ")"));
    const ids = stale.map(t => t.TenantId);
    if (ids.length) {
      db.Tenants.deleteMany({ TenantId: { $in: ids } });
      db.ProjectPeoples.deleteMany({ TenantId: { $in: ids } });
      db.TenantAssets.deleteMany({ TenantGroupId: { $nin: [root ? root.TenantGroupId : null] } });
    }
    print("    tenants remaining: " + db.Tenants.countDocuments({}));
  '
fi

echo "==> dumping"
# Session state is runtime data, not seed data.
docker exec mongodb sh -c "rm -rf /tmp/dump && mongodump --uri '$URI' \
  --db '$ROOT_DB' \
  --excludeCollection IdpSessions \
  --excludeCollection IdpRefreshTokens \
  --excludeCollection IdpAuthorizationCodes \
  --excludeCollection NotificationConnections \
  --out /tmp/dump" 2>&1 | grep -c 'done dumping' | sed 's/^/    '"$ROOT_DB"': /;s/$/ collections/'

docker exec mongodb sh -c "mongodump --uri '$URI' --db BlocksConfiguration --out /tmp/dump" 2>&1 \
  | grep -c 'done dumping' | sed 's/^/    BlocksConfiguration: /;s/$/ collections/'

rm -rf "$_root/$ROOT_DB" "$_root/BlocksConfiguration"
docker cp "mongodb:/tmp/dump/$ROOT_DB" "$_root/$ROOT_DB" >/dev/null
docker cp "mongodb:/tmp/dump/BlocksConfiguration" "$_root/BlocksConfiguration" >/dev/null

echo
echo "Dumps written to $_root/{$ROOT_DB,BlocksConfiguration}."
echo "docker compose up -d will now seed through upstream's mongodb-seed."
