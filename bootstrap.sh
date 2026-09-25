#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════
# NotaServer Bootstrap — downloads and runs the installer
# ═══════════════════════════════════════════════════════════════════════════
set -e

INSTALLER_REPO="${NOTASERVER_INFRA_REPO:-https://github.com/launchlean/notaserver-infra}"
INSTALLER_BRANCH="${NOTASERVER_INFRA_BRANCH:-main}"
INSTALLER_PATH="${NOTASERVER_INSTALLER_PATH:-installer.sh}"
INSTALLER_URL="${INSTALLER_REPO}/raw/${INSTALLER_BRANCH}/${INSTALLER_PATH}"
MANIFEST_URL="${INSTALLER_REPO}/raw/${INSTALLER_BRANCH}/${INSTALLER_PATH}.sha256"
TEMP_DIR=""

log() { echo "$1"; }

cleanup() { [ -n "$TEMP_DIR" ] && [ -d "$TEMP_DIR" ] && rm -rf "$TEMP_DIR"; }
trap cleanup EXIT

fetch_with_cachebust() {
    local url="$1" output="$2"
    curl -fSL --max-time 60 -H "Cache-Control: no-cache" \
        "${url}?$(date +%s)" -o "$output" 2>/dev/null || \
    curl -fSL --max-time 60 -o "$output" "$url" 2>/dev/null
}

fetch_manifest() {
    local out="$1"
    if fetch_with_cachebust "$MANIFEST_URL" "$out" 2>/dev/null; then
        if grep -qE '^[a-f0-9]{64} ' "$out" 2>/dev/null; then
            return 0
        fi
    fi
    local api_url="https://api.github.com/repos/launchlean/notaserver-infra/contents/${INSTALLER_PATH}.sha256"
    local js; js=$(mktemp)
    if curl -sf --max-time 30 -H "Accept: application/vnd.github.v3+json" \
        "$api_url" -o "$js" 2>/dev/null; then
        python3 - "$js" "$out" << 'PYEOF'
import json, base64, sys
with open(sys.argv[1]) as f:
    d = json.load(f)
decoded = base64.b64decode(d["content"]).decode()
with open(sys.argv[2], "w") as out:
    out.write(decoded)
PYEOF
        [ -s "$out" ] && { rm -f "$js"; return 0; }
    fi
    rm -f "$js"
    return 1
}

# Main
log "NotaServer Bootstrap"
log "==================="
log ""

if [ "$(id -u)" -ne 0 ]; then
    log "Error: Must be run as root."
    log "       sudo $0"
    exit 1
fi

if ! command -v curl >/dev/null 2>&1; then
    log "Error: curl is required."
    exit 1
fi

if ! command -v sha256sum >/dev/null 2>&1; then
    log "Error: sha256sum is required."
    exit 1
fi

TEMP_DIR=$(mktemp -d)
cd "$TEMP_DIR"

log "Downloading installer..."
log "  From: ${INSTALLER_URL}"

if ! curl -fSL --max-time 60 -o "$INSTALLER_PATH" "$INSTALLER_URL"; then
    log "Error: Failed to download installer."
    exit 1
fi

log "  Downloaded: $(wc -c < "$INSTALLER_PATH") bytes"

if [ "${SKIP_VERIFY:-no}" != "yes" ]; then
    log "  Verifying SHA256..."
    MANIFEST_OK=false
    for attempt in 1 2 3; do
        case $attempt in
            1) log "  Fetching manifest (raw)..." ;;
            2) log "  Fetching manifest (API fallback)..." ;;
            3) log "  Retrying raw manifest..." ;;
        esac
        if ! fetch_manifest "$INSTALLER_PATH.sha256"; then
            log "  Error: Failed to download manifest (attempt $attempt)."
            continue
        fi
        EXPECTED_HASH=$(cat "$INSTALLER_PATH.sha256" | cut -d' ' -f1 | tr -d '[:space:]')
        ACTUAL_HASH=$(sha256sum "$INSTALLER_PATH" | cut -d' ' -f1 | tr -d '[:space:]')
        if [ -n "$EXPECTED_HASH" ] && [ "$EXPECTED_HASH" = "$ACTUAL_HASH" ]; then
            MANIFEST_OK=true; log "  Verified: SHA256 OK"; break
        else
            log "  Hash mismatch (attempt $attempt):"
            log "    expected: ${EXPECTED_HASH:0:16}..."
            log "    actual:   ${ACTUAL_HASH:0:16}..."
            [ "$attempt" = "3" ] && {
                log ""; log "  Integrity check failed."; log ""
                log "  Options:"
                log "    1. Wait and retry (GitHub CDN cache)"
                log "    2. Set SKIP_VERIFY=yes (dev only)"
                log "    3. Check locally: sha256sum installer.sh"
                exit 1
            }
        fi
    done
fi

log ""
chmod +x "$INSTALLER_PATH"

log "Starting installer..."
log ""

if [ "${NON_INTERACTIVE:-}" = "true" ] || [ "${NON_INTERACTIVE:-}" = "1" ]; then
    ./"$INSTALLER_PATH" --non-interactive "$@"
else
    ./"$INSTALLER_PATH" "$@"
fi

EXIT_CODE=$?
cd /; rm -rf "$TEMP_DIR"; TEMP_DIR=""
exit $EXIT_CODE
