# こんな感じのcron
# */3 * * * * flock -n /tmp/hackisskey-update.lock -c 'cd /home/hackisskey/hackisskey-infra && ./scripts/update.sh'
# 実行権限に注意

# by claude

#!/bin/bash
set -euo pipefail

COMPOSE_FILE="./compose.yml"
COMPOSE_PROJECT="hackisskey"
STATUS_FILE="html/down/update.json"

# updateファイルが残ってたら消す（多重起動しないようにはcron側で担保）
rm -f "$STATUS_FILE"

# イメージのバージョンラベルを取得
get_version() {
  docker image inspect "$1" \
    --format '{{index .Config.Labels "org.opencontainers.image.version"}}' \
    2>/dev/null || echo "unknown"
}

# compose config からサービス→イメージ名のマッピングを取得
get_service_images() {
  docker compose -p "$COMPOSE_PROJECT" -f "$COMPOSE_FILE" \
    config --format json 2>/dev/null \
  | python3 -c "
import json, sys
cfg = json.load(sys.stdin)
for svc, val in cfg.get('services', {}).items():
    img = val.get('image', '')
    if img:
        print(svc, img)
"
}

# ----- 現在稼働中のバージョンを記録 -----
declare -A FROM_VERSIONS
while IFS= read -r line; do
  service=$(awk '{print $1}' <<< "$line")
  image=$(awk '{print $2}'   <<< "$line")
  FROM_VERSIONS["$service"]=$(get_version "$image")
done < <(
  docker compose -p "$COMPOSE_PROJECT" -f "$COMPOSE_FILE" \
    ps --format "{{.Service}} {{.Image}}" 2>/dev/null
)

# ----- 最新イメージを pull（バージョン差分検出のため） -----
echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Pulling images..."
docker compose -p "$COMPOSE_PROJECT" -f "$COMPOSE_FILE" pull --quiet

# ----- pull 後のバージョンを取得 -----
declare -A TO_VERSIONS
while IFS= read -r line; do
  service=$(awk '{print $1}' <<< "$line")
  image=$(awk '{print $2}'   <<< "$line")
  TO_VERSIONS["$service"]=$(get_version "$image")
done < <(get_service_images)

# ----- 差分チェック -----
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

# ----- メンテナンス用ステータスファイルを作成 -----
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

# ----- コンテナ更新（pull already済みなので --pull always は実質キャッシュ利用） -----
docker compose -p "$COMPOSE_PROJECT" -f "$COMPOSE_FILE" \
  up -d --pull always --remove-orphans

sleep 1

# ----- ヘルスチェック待機 -----
echo "Waiting for all services to be healthy..."
TIMEOUT=120
ELAPSED=0
while [ "$ELAPSED" -lt "$TIMEOUT" ]; do
  NOT_READY=$(
    docker compose -p "$COMPOSE_PROJECT" -f "$COMPOSE_FILE" \
      ps --format "{{.Health}}" 2>/dev/null \
    | grep -cE "starting|unhealthy" || true
  )
  if [ "$NOT_READY" = "0" ]; then
    break
  fi
  echo "  Still waiting... (${ELAPSED}s)"
  sleep 5
  ELAPSED=$((ELAPSED + 5))
done

if [ "$ELAPSED" -ge "$TIMEOUT" ]; then
  echo "[WARN] Health check timed out. Status file kept."
  trap - EXIT
  exit 1
fi

sleep 120

# ----- 完了 -----
trap - EXIT
rm -f "$STATUS_FILE"
echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Update complete!"