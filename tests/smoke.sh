#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")/.."

test_dir=$(mktemp -d)
export COMPOSE_PROJECT_NAME="dind-smoke-$$"
export DIND_IMAGE="${DIND_SMOKE_IMAGE:-dind-smoke:local}"
export SSH_PORT=38222 SERVICE_PORT=38777 DIND_SERVICE_PORT=38778
export SSH_AUTHORIZED_KEYS="$test_dir/key.pub" GH_TOKEN= GHCR_TOKEN=
compose() {
    if [ -n "${DIND_SMOKE_RELEASE_FILE:-}" ]; then
        docker compose --project-directory "$PWD" -f "$DIND_SMOKE_RELEASE_FILE" -f "$PWD/tests/compose.test.yml" "$@"
    else
        ./compose -f tests/compose.test.yml "$@"
    fi
}
cleanup() {
    compose down -v || true
    rm -f "$test_dir/key" "$test_dir/key.pub" "$test_dir/known_hosts"
    rmdir "$test_dir"
}
trap cleanup EXIT
ssh-keygen -q -t ed25519 -N '' -f "$test_dir/key"
if [ -n "${DIND_SMOKE_RELEASE_FILE:-}" ]; then
    compose up -d
else
    compose up -d --build
fi

agent=$COMPOSE_PROJECT_NAME
docker exec -i -u agent "$agent" bash < tests/documents.sh
# Shared libraries that Playwright's downloaded Chromium links against.
docker exec -u agent "$agent" sh -ec 'for lib in libasound.so.2 libatk-1.0.so.0 libatk-bridge-2.0.so.0 libatspi.so.0 libcairo.so.2 libcups.so.2 libdbus-1.so.3 libdrm.so.2 libgbm.so.1 libglib-2.0.so.0 libnspr4.so libnss3.so libpango-1.0.so.0 libX11.so.6 libxcb.so.1 libXcomposite.so.1 libXdamage.so.1 libXext.so.6 libXfixes.so.3 libxkbcommon.so.0 libXrandr.so.2; do /sbin/ldconfig -p | grep -Fq "$lib " || { echo "Missing Chromium library: $lib" >&2; exit 1; }; done'
image_size=$(docker image inspect "$DIND_IMAGE" --format '{{.Size}}')
printf 'Agent image size: %s bytes\n' "$image_size"
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    printf 'Agent image size (uncompressed): %s bytes\n' "$image_size" >> "$GITHUB_STEP_SUMMARY"
fi
for _ in $(seq 1 30); do
    if ssh -o BatchMode=yes -o ConnectTimeout=2 -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile="$test_dir/known_hosts" -i "$test_dir/key" \
        -p "$SSH_PORT" agent@127.0.0.1 'docker version --format "{{.Server.Version}}" && docker compose version'; then
        break
    fi
    sleep 1
done
# Fail if SSH has not become usable.
ssh -o BatchMode=yes -o ConnectTimeout=2 -o StrictHostKeyChecking=yes \
    -o UserKnownHostsFile="$test_dir/known_hosts" -i "$test_dir/key" \
    -p "$SSH_PORT" agent@127.0.0.1 'docker info >/dev/null && docker compose version'

docker exec -u agent "$agent" sh -ec 'test -r "$HOME/.codex/AGENTS.md" && test -r "$HOME/.claude/CLAUDE.md" && cmp "$HOME/.codex/AGENTS.md" "$HOME/.claude/CLAUDE.md" && grep -q "in English" "$HOME/.codex/AGENTS.md"'
docker exec -u agent "$agent" sh -ec 'mkdir -p /workspaces/smoke && printf copied-ok > /workspaces/smoke/probe'
docker exec -u agent "$agent" docker run -d --name nested-smoke \
    -p 7778:6379 redis:7-alpine
for _ in $(seq 1 30); do
    if [ "$(docker exec -u agent "$agent" docker exec nested-smoke redis-cli ping 2>/dev/null || true)" = PONG ]; then break; fi
    sleep 1
done
[ "$(docker exec -u agent "$agent" docker exec nested-smoke redis-cli ping)" = PONG ]
docker exec -u agent "$agent" docker cp /workspaces/smoke/probe nested-smoke:/probe
[ "$(docker exec -u agent "$agent" docker exec nested-smoke cat /probe)" = copied-ok ]
docker exec -u agent "$agent" sh -ec "printf 'FROM redis:7-alpine\\nCOPY probe /probe\\n' > /workspaces/smoke/Dockerfile"
docker exec -u agent "$agent" docker build -t smoke-workspace /workspaces/smoke
[ "$(docker exec -u agent "$agent" docker run --rm smoke-workspace cat /probe)" = copied-ok ]
docker exec -u agent "$agent" node -e 'const s=require("net").connect(7778,"127.0.0.1",()=>s.write("*1\r\n$4\r\nPING\r\n"));s.on("data",b=>{if(b.toString().trim()!=="+PONG")process.exit(1);s.end()});s.on("error",()=>process.exit(1));setTimeout(()=>process.exit(1),5000).unref()'
docker exec -i -u agent "$agent" bash < tests/browser.sh
if docker inspect "$agent" --format '{{range .Mounts}}{{println .Destination}}{{end}}' | grep -Fxq /workspaces; then
    echo 'Workspace has an unexpected mount' >&2; exit 1
fi
dind=$(compose ps -q dind)
if docker inspect "$dind" --format '{{range .Mounts}}{{println .Type}}{{end}}' | grep -Fxq volume; then
    echo 'DinD has an unexpected Docker volume' >&2; exit 1
fi
if docker ps -a --format '{{.Names}}' | grep -Fxq nested-smoke; then
    echo 'Nested container is visible to the host daemon' >&2; exit 1
fi
if docker exec -u agent "$agent" docker ps -a --format '{{.Names}}' | grep -Fxq "$agent"; then
    echo 'Host agent container is visible to the inner daemon' >&2; exit 1
fi
for key in title description url documentation source vendor; do
    value=$(docker inspect "$agent" --format "{{ index .Config.Labels \"org.opencontainers.image.$key\" }}")
    if [ -z "$value" ] || [ "$value" = '<no value>' ]; then
        echo "Missing OCI image label: $key" >&2; exit 1
    fi
done
compose restart dind
for _ in $(seq 1 45); do
    if docker exec -u agent "$agent" docker info >/dev/null 2>&1; then break; fi
    sleep 1
done
docker exec -u agent "$agent" docker info >/dev/null
if docker exec -u agent "$agent" docker ps -a --format '{{.Names}}' | grep -Fxq nested-smoke; then
    echo 'Inner containers unexpectedly survived a DinD restart' >&2; exit 1
fi
docker exec -u agent "$agent" test -f /workspaces/smoke/probe
compose up -d --force-recreate
docker exec -u agent "$agent" test ! -e /workspaces/smoke/probe
printf '%s\n' 'Smoke test passed: documents, OCR, images, Playwright Chromium, SSH, Docker, Compose, Redis, build, networking, labels, ephemeral storage and daemon separation.'
