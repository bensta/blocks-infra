#!/usr/bin/env bash
# resolve-tags.sh — pin <SVC>_TAG in .env to the newest amd64 tag on Docker Hub.
#
# docker-compose.yml resolves images as ${OS_TAG:-latest}, but no `latest` tag is
# published (apps.yml says so explicitly, and the registry confirms it: every tag
# is a commit SHA). run.sh resolves tags at deploy time; plain `docker compose`
# does not, so the tags have to be pinned in .env for compose to work unedited.
#
# Only tags with an amd64 image are considered — there are no arm64 builds.
set -euo pipefail

_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
_env="$_root/.env"
[[ -f "$_env" ]] || { echo "resolve-tags.sh: no .env at $_env" >&2; exit 1; }

services=(os iam data logic localization studio release monitor agents utilities)

for svc in "${services[@]}"; do
  var="$(printf '%s' "$svc" | tr 'a-z' 'A-Z')_TAG"
  tag="$(curl -fsS "https://hub.docker.com/v2/repositories/blocksos/blocks-${svc}-api/tags?page_size=25" 2>/dev/null \
    | python3 -c "
import sys, json
try:
    rs = json.load(sys.stdin).get('results', [])
except Exception:
    print(''); raise SystemExit
for t in rs:                                   # newest first
    if any(i.get('architecture') == 'amd64' for i in (t.get('images') or [])):
        print(t['name']); break
else:
    print('')
" || true)"

  if [[ -z "$tag" ]]; then
    printf '  %-14s no amd64 tag found — leaving unchanged\n' "$svc" >&2
    continue
  fi

  if grep -qE "^${var}=" "$_env"; then
    # BSD and GNU sed disagree about -i; write through a temp file instead.
    sed "s|^${var}=.*|${var}=${tag}|" "$_env" > "$_env.tmp" && mv "$_env.tmp" "$_env"
  else
    printf '%s=%s\n' "$var" "$tag" >> "$_env"
  fi
  printf '  %-14s %s\n' "$svc" "$tag"
done

echo
echo "Pinned in .env. Pull with:  docker compose --profile apps pull"
