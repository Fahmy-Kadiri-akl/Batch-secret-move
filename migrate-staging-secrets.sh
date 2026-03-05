#!/usr/bin/env bash
#
# migrate-staging-secrets.sh
#
# Moves Akeyless static secrets from a source path to destination paths.
#
# Source: <source>/<env>/<app>/<secrets>
# Target: <target-prefix>/<env>/<app>/static-secrets/<secrets>
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

# List all secrets under a path as: <item_name>
# Single python process handles recursion internally to minimize overhead
list_secrets() {
    python3 -c "
import json, subprocess
def ls(p):
    r = subprocess.run(['akeyless','list-items','--path',p,'--minimal-view','true','--auto-pagination','enabled','--json'], capture_output=True, text=True)
    try: d = json.loads(r.stdout)
    except: return
    for i in d.get('items',[]):
        if i.get('item_type')=='STATIC_SECRET': print(i['item_name'])
    for f in d.get('folders',[]): ls(f.rstrip('/'))
ls('$1')
"
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

    # One recursive call per env — gets all secrets across all apps
    secrets=$(list_secrets "$env_path")
    [[ -z "$secrets" ]] && { log_warn "No secrets under ${env_path}, skipping"; continue; }

    log_info "Environment: ${env}"
    cur_app=""

    while IFS= read -r secret_path; do
        # Parse: <env_path>/<app_name>/.../<secret_name>
        relative="${secret_path#"${env_path}/"}"
        app_name="${relative%%/*}"
        secret_relative="${relative#"${app_name}/"}"

        [[ -n "$FILTER_APP" && "$app_name" != "$FILTER_APP" ]] && continue

        target="${TARGET_PREFIX}/${env}/${app_name}/static-secrets/${secret_relative}"

        # Log app header on change
        [[ "$app_name" != "$cur_app" ]] && { cur_app="$app_name"; log_info "  ${app_name}"; }

        if $DRY_RUN; then
            log_warn "    ${secret_relative} → ${target}"
            MOVED=$((MOVED + 1))
            continue
        fi

        # Read → Create → Delete
        value=$(akeyless get-secret-value --name "$secret_path" 2>/dev/null) || true
        if [[ -z "$value" || "$value" == "null" ]]; then
            log_error "    FAIL read: ${secret_relative}"; FAILED=$((FAILED + 1)); continue
        fi

        if ! akeyless create-secret --name "$target" --value "$value" &>/dev/null; then
            log_error "    FAIL create: ${secret_relative}"; FAILED=$((FAILED + 1)); continue
        fi

        akeyless delete-item --name "$secret_path" &>/dev/null || \
            log_warn "    created ${target} but failed to delete source"

        log_ok "    ${secret_relative} → ${target}"
        MOVED=$((MOVED + 1))
    done <<< "$secrets"
    echo ""
done

log_info "=== Done: ${MOVED} moved, ${FAILED} failed ==="
$DRY_RUN && log_warn "Dry run — re-run without --dry-run to execute."
[[ $FAILED -gt 0 ]] && exit 1
exit 0
