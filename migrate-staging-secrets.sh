#!/usr/bin/env bash
#
# migrate-staging-secrets.sh
#
# Moves Akeyless static secrets from a source path to destination paths,
# preserving all secret versions.
#
# Source: <source>/<env>/<app>/<secrets>
# Target: <target-prefix>/<env>/<app>/static-secrets/<secrets>
#
# Strategy:
#   1. Try move-objects per app folder (fast, preserves versions/metadata)
#   2. If target path already exists, fall back to version-aware per-item copy
#
# Usage:
#   ./migrate-staging-secrets.sh --source <path> --envs <env1,env2,...> [OPTIONS]
#
# Required:
#   --source <path>          Source folder (e.g. /staging)
#   --envs <env1,env2,...>   Comma-separated environments
#
# Options:
#   --target-prefix <path>   Destination base path (default: "")
#   --dry-run                Preview without executing
#   --app <app>              Filter to one application
#   --help                   Show this help

set -euo pipefail

SOURCE="" TARGET_PREFIX="" DRY_RUN=false FILTER_APP=""
ENVS=()
MOVED=0 FAILED=0

log_info()  { echo -e "\033[0;34m[INFO]\033[0m  $*"; }
log_ok()    { echo -e "\033[0;32m[OK]\033[0m    $*"; }
log_warn()  { echo -e "\033[1;33m[WARN]\033[0m  $*"; }
log_error() { echo -e "\033[0;31m[ERROR]\033[0m $*"; }

usage() { sed -n '/^# Usage:/,/^$/p' "$0" | sed 's/^# \?//'; exit 0; }

# List app folders under a path (one line per folder, no trailing slash)
list_folders() {
    akeyless list-items --path "$1" --minimal-view true --auto-pagination enabled --json 2>/dev/null \
        | python3 -c "
import json, sys
try:
    for f in json.load(sys.stdin).get('folders', []): print(f.rstrip('/'))
except: pass
" 2>/dev/null || true
}

# List secrets with version counts: <item_name>\t<last_version>
list_secrets() {
    python3 -c "
import json, subprocess
def ls(p):
    r = subprocess.run(['akeyless','list-items','--path',p,'--minimal-view','true','--auto-pagination','enabled','--json'], capture_output=True, text=True)
    try: d = json.loads(r.stdout)
    except: return
    for i in d.get('items',[]):
        if i.get('item_type')=='STATIC_SECRET': print(i['item_name'] + '\t' + str(i.get('last_version',1)))
    for f in d.get('folders',[]): ls(f.rstrip('/'))
ls('$1')
"
}

# Check if a path has any items or subfolders
path_has_content() {
    local result
    result=$(akeyless list-items --path "$1" --minimal-view true --json 2>/dev/null) || return 1
    python3 -c "
import json, sys
d = json.loads('''$result''')
sys.exit(0 if d.get('items') or d.get('folders') else 1)
" 2>/dev/null
}

# Migrate a single secret with all versions preserved
# Args: source_path target_path last_version
migrate_secret_with_versions() {
    local src="$1" tgt="$2" versions="$3"

    # Version 1: create
    local v1
    v1=$(akeyless get-secret-value --name "$src" --version 1 2>/dev/null) || true
    if [[ -z "$v1" || "$v1" == "null" ]]; then
        log_error "    FAIL read v1: ${src}"; return 1
    fi
    if ! akeyless create-secret --name "$tgt" --value "$v1" &>/dev/null; then
        log_error "    FAIL create: ${tgt}"; return 1
    fi

    # Versions 2..N: update with keep-prev-version
    local v
    for ((v=2; v<=versions; v++)); do
        local val
        val=$(akeyless get-secret-value --name "$src" --version "$v" 2>/dev/null) || true
        if [[ -z "$val" || "$val" == "null" ]]; then
            log_warn "    SKIP version ${v}: ${src} (unreadable)"; continue
        fi
        if ! akeyless update-secret-val --name "$tgt" --value "$val" --keep-prev-version true &>/dev/null; then
            log_warn "    FAIL write version ${v}: ${tgt}"; continue
        fi
    done

    # Delete source
    akeyless delete-item --name "$src" &>/dev/null || \
        log_warn "    created ${tgt} but failed to delete source"
    return 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --source)        SOURCE="$2"; shift 2 ;;
        --target-prefix) TARGET_PREFIX="$2"; shift 2 ;;
        --envs)          IFS=',' read -ra ENVS <<< "$2"; shift 2 ;;
        --dry-run)       DRY_RUN=true; shift ;;
        --app)           FILTER_APP="$2"; shift 2 ;;
        --help)          usage ;;
        *) log_error "Unknown option: $1"; usage ;;
    esac
done

[[ -z "$SOURCE" ]] && { log_error "--source is required"; usage; }
[[ ${#ENVS[@]} -eq 0 ]] && { log_error "--envs is required (e.g. dev,qa,prod)"; usage; }
command -v akeyless &>/dev/null || { log_error "akeyless CLI not found"; exit 1; }

log_info "=== Akeyless Static Secrets Migration ==="
log_info "Source:  ${SOURCE}/<env>/<app>/*"
log_info "Target:  ${TARGET_PREFIX}/<env>/<app>/static-secrets/*"
log_info "Envs:    ${ENVS[*]}"
$DRY_RUN && log_warn "DRY-RUN MODE"
echo ""

for env in "${ENVS[@]}"; do
    env_path="${SOURCE}/${env}"

    app_folders=$(list_folders "$env_path")
    [[ -z "$app_folders" ]] && { log_warn "No apps under ${env_path}, skipping"; continue; }

    log_info "Environment: ${env}"

    while IFS= read -r app_path; do
        [[ -z "$app_path" ]] && continue
        app_name=$(basename "$app_path")
        [[ -n "$FILTER_APP" && "$app_name" != "$FILTER_APP" ]] && continue

        source_folder="${app_path}/"
        target_folder="${TARGET_PREFIX}/${env}/${app_name}/static-secrets/"

        if $DRY_RUN; then
            # Show individual secrets for dry-run
            secrets=$(list_secrets "$app_path")
            [[ -z "$secrets" ]] && continue
            log_info "  ${app_name}"
            while IFS=$'\t' read -r secret_path last_ver; do
                relative="${secret_path#"${app_path}/"}"
                target="${target_folder}${relative}"
                log_warn "    ${relative} (${last_ver} ver) → ${target}"
                MOVED=$((MOVED + 1))
            done <<< "$secrets"
            continue
        fi

        # Check if target path already has content
        if path_has_content "$target_folder"; then
            # FALLBACK: target exists — move-objects would nest incorrectly
            # Use version-aware per-item migration instead
            log_warn "  ${app_name}: target exists, using per-item migration (preserving versions)"
            secrets=$(list_secrets "$app_path")
            [[ -z "$secrets" ]] && continue

            while IFS=$'\t' read -r secret_path last_ver; do
                relative="${secret_path#"${app_path}/"}"
                target="${target_folder}${relative}"
                if migrate_secret_with_versions "$secret_path" "$target" "$last_ver"; then
                    log_ok "    ${relative} (${last_ver} ver) → ${target}"
                    MOVED=$((MOVED + 1))
                else
                    FAILED=$((FAILED + 1))
                fi
            done <<< "$secrets"
        else
            # FAST PATH: target doesn't exist — move-objects preserves everything
            log_info "  ${app_name}: using move-objects"
            if akeyless move-objects --source "$source_folder" --target "$target_folder" &>/dev/null; then
                count=$(list_secrets "$target_folder" | wc -l)
                log_ok "  ${app_name}: moved ${count} secret(s) with all versions"
                MOVED=$((MOVED + count))
            else
                log_error "  ${app_name}: move-objects failed"
                FAILED=$((FAILED + 1))
            fi
        fi
    done <<< "$app_folders"
    echo ""
done

log_info "=== Done: ${MOVED} moved, ${FAILED} failed ==="
$DRY_RUN && log_warn "Dry run — re-run without --dry-run to execute."
[[ $FAILED -gt 0 ]] && exit 1
exit 0
