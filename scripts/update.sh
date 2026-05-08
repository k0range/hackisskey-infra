#!/bin/bash
set -euo pipefail

COMPOSE_FILE="./compose.yml"
COMPOSE_PROJECT="hackisskey"
STATUS_FILE="html/down/update.json"

# Get image version label
get_version() {
  local image="$1"
  docker image inspect "$image" \
    --format '{{index .Config.Labels "org.opencontainers.image.version"}}' \
    2>/dev/null || echo "unknown"
}

# Get current version label
declare -A FROM_VERSIONS
while IFS= read -r line; do
  service=$(echo "$line" | awk '{print $1}')
  image=$(echo "$line"   | awk '{print $2}')
  FROM_VERSIONS["$service"]=$(get_version "$image")
done < <(
  docker compose -p "$COMPOSE_PROJECT" -f "$COMPOSE_FILE" \
    ps --format "{{.Service}} {{.Image}}" 2>/dev/null
)

echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Pulling images..."
docker compose -p "$COMPOSE_PROJECT" -f "$COMPOSE_FILE" pull --quiet

# Get new version label
declare -A TO_VERSIONS
declare -A SERVICES_MAP
while IFS= read -r line; do
  service=$(echo "$line" | awk '{print $1}')
  image=$(echo "$line"   | awk '{print $2}')
  TO_VERSIONS["$service"]=$(get_version "$image")
  SERVICES_MAP["$service"]="$image"
done < <(
  docker compose -p "$COMPOSE_PROJECT" -f "$COMPOSE_FILE" \
    config --format json | \
    docker run --rm -i stedolan/jq -r \
      '.services | to_entries[] | "\(.key) \(.value.image)"' \
    2>/dev/null || \

  # fallback if jq is not available
  grep -A1 'image:' "$COMPOSE_FILE" | grep -v '^--$' | \
    awk '/image:/{img=$2} /container_name:/{print $2, img}'
)

# check update diffs
NEEDS_UPDATE=false
DIFF_JSON="["
FIRST=true
for service in "${!TO_VERSIONS[@]}"; do
  from="${FROM_VERSIONS[$service]:-unknown}"
  to="${TO_VERSIONS[$service]:-unknown}"
  if [ "$from" != "$to" ]; then
    NEEDS_UPDATE=true
    [ "$FIRST" = true ] && FIRST=false || DIFF_JSON+=","
    DIFF_JSON+="{\"service\":\"$service\",\"from\":\"$from\",\"to\":\"$to\"}"
  fi
done
DIFF_JSON+="]"

# debug
#NEEDS_UPDATE=true
#DIFF_JSON="[{\"service\":\"misskey\",\"from\":\"v1\",\"to\":\"v2\"}]"
# end debug

if [ "$NEEDS_UPDATE" = false ]; then
  echo "All services are up to date. Nothing to do."
  exit 0
fi

# Create status file
cat > "$STATUS_FILE" <<EOF
{
  "project":    "$COMPOSE_PROJECT",
  "started_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "updates":    $DIFF_JSON
}
EOF

echo "Status file created: $STATUS_FILE"
echo "Updating services: $DIFF_JSON"

cleanup() {
  local exit_code=$?
  if [ $exit_code -ne 0 ]; then
    echo "[ERROR] Update failed (exit: $exit_code). Removing status file."
    rm -f "$STATUS_FILE"
  fi
}
trap cleanup EXIT

# do update
docker compose -p "$COMPOSE_PROJECT" -f "$COMPOSE_FILE" up -d --remove-orphans

# wait 1s
sleep 1

# wait for health
echo "Waiting for all services to be healthy..."
TIMEOUT=120
ELAPSED=0
while [ $ELAPSED -lt $TIMEOUT ]; do
  # unhealthy / starting のコンテナが 0 になるまで待つ
  NOT_READY=$(
    docker compose -p "$COMPOSE_PROJECT" -f "$COMPOSE_FILE" \
      ps --format "{{.Health}}" 2>/dev/null | \
      grep -cE "starting|unhealthy" || true
  )
  if [ "$NOT_READY" = "0" ]; then
    break
  fi
  echo "  Still waiting... ($ELAPSED s)"
  sleep 5
  ELAPSED=$((ELAPSED + 5))
done

if [ $ELAPSED -ge $TIMEOUT ]; then
  echo "[WARN] Health check timed out. Status file kept."
  trap - EXIT
  exit 1
fi

sleep 120

# update complete
trap - EXIT
rm -f "$STATUS_FILE"
echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Update complete!"
