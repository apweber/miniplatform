#!/usr/bin/env bash
# =============================================================================
# health_check.sh — Server health monitor for MiniPlatform (Phase 1 capstone)
#
# Checks: CPU usage, memory usage, disk usage, and key service status.
# Alerts: writes to stderr + log file; optionally POSTs to a Slack webhook.
# Config: reads thresholds and settings from health_check.conf (same dir).
#
# Usage:
#   ./health_check.sh              # single run
#   ./health_check.sh --quiet      # suppress stdout, only log
#   ./health_check.sh --report     # print a summary report and exit
#
# Install as cron (every 5 minutes):
#   */5 * * * * /opt/miniplatform/scripts/health_check.sh --quiet
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Resolve script directory (works even if called from another path)
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# Defaults — overridden by health_check.conf if it exists
# ---------------------------------------------------------------------------
LOG_FILE="${LOG_FILE:-/var/log/miniplatform/health.log}"
CPU_WARN_PCT="${CPU_WARN_PCT:-75}"
CPU_CRIT_PCT="${CPU_CRIT_PCT:-90}"
MEM_WARN_PCT="${MEM_WARN_PCT:-80}"
MEM_CRIT_PCT="${MEM_CRIT_PCT:-95}"
DISK_WARN_PCT="${DISK_WARN_PCT:-75}"
DISK_CRIT_PCT="${DISK_CRIT_PCT:-90}"
DISK_PATH="${DISK_PATH:-/}"
SERVICES="${SERVICES:-docker nginx}"        # space-separated systemd units
CPU_SAMPLES="${CPU_SAMPLES:-3}"             # samples averaged for CPU reading
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"          # empty = Slack alerts disabled
ALERT_COOLDOWN_SECS="${ALERT_COOLDOWN_SECS:-300}"  # 5 min between repeat alerts
COOLDOWN_DIR="${COOLDOWN_DIR:-/tmp/health_check_cooldowns}"
HOSTNAME_LABEL="${HOSTNAME_LABEL:-$(hostname -s)}"

# ---------------------------------------------------------------------------
# Load config file (silently skip if missing)
# ---------------------------------------------------------------------------
CONFIG_FILE="${SCRIPT_DIR}/health_check.conf"
if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
fi

# ---------------------------------------------------------------------------
# Parse flags
# ---------------------------------------------------------------------------
QUIET=false
REPORT_MODE=false
for arg in "$@"; do
    case "$arg" in
        --quiet)  QUIET=true ;;
        --report) REPORT_MODE=true ;;
        --help)
            echo "Usage: $0 [--quiet] [--report] [--help]"
            echo "  --quiet   Suppress stdout output; only write to log"
            echo "  --report  Print a one-shot status report and exit"
            exit 0
            ;;
        *)
            echo "Unknown option: $arg" >&2
            exit 1
            ;;
    esac
done

# ---------------------------------------------------------------------------
# Ensure log directory exists
# ---------------------------------------------------------------------------
LOG_DIR="$(dirname "$LOG_FILE")"
if [[ ! -d "$LOG_DIR" ]]; then
    mkdir -p "$LOG_DIR" || {
        echo "ERROR: cannot create log directory $LOG_DIR" >&2
        exit 1
    }
fi

# Cooldown dir for deduplicating alerts
mkdir -p "$COOLDOWN_DIR"

# ---------------------------------------------------------------------------
# Logging helpers
# ---------------------------------------------------------------------------
_timestamp() { date '+%Y-%m-%dT%H:%M:%S%z'; }

log() {
    local level="$1"
    shift
    local msg="$*"
    local line
    line="$(_timestamp) [$level] $msg"
    echo "$line" >> "$LOG_FILE"
    if [[ "$QUIET" == false ]]; then
        echo "$line"
    fi
}

log_info()  { log "INFO " "$@"; }
log_warn()  { log "WARN " "$@"; }
log_crit()  { log "CRIT " "$@"; }
log_ok()    { log "OK   " "$@"; }

# ---------------------------------------------------------------------------
# Cooldown: skip re-alerting the same key within ALERT_COOLDOWN_SECS
# Returns 0 if alert should fire, 1 if still cooling down
# ---------------------------------------------------------------------------
should_alert() {
    local key="${1//[^a-zA-Z0-9_-]/_}"   # sanitise for filename
    local stamp_file="$COOLDOWN_DIR/$key"
    local now
    now=$(date +%s)

    if [[ -f "$stamp_file" ]]; then
        local last_sent
        last_sent=$(cat "$stamp_file")
        local elapsed=$(( now - last_sent ))
        if (( elapsed < ALERT_COOLDOWN_SECS )); then
            return 1   # still cooling down
        fi
    fi

    echo "$now" > "$stamp_file"
    return 0
}

# ---------------------------------------------------------------------------
# Slack alerting
# ---------------------------------------------------------------------------
send_slack() {
    local severity="$1"   # WARN or CRIT
    local check="$2"
    local detail="$3"

    [[ -z "$SLACK_WEBHOOK" ]] && return 0

    local emoji icon
    if [[ "$severity" == "CRIT" ]]; then
        emoji=":red_circle:"
        icon="critical"
    else
        emoji=":warning:"
        icon="warning"
    fi

    local payload
    payload=$(cat <<EOF
{
  "text": "${emoji} *[${severity}] ${HOSTNAME_LABEL}* — ${check}",
  "attachments": [
    {
      "color": "$([ "$severity" == "CRIT" ] && echo "danger" || echo "warning")",
      "text": "${detail}",
      "footer": "health_check.sh | $(date '+%Y-%m-%d %H:%M:%S')"
    }
  ]
}
EOF
)
    curl -s -X POST \
         -H 'Content-type: application/json' \
         --data "$payload" \
         "$SLACK_WEBHOOK" \
         --max-time 5 \
         --retry 2 \
         > /dev/null 2>&1 || true
}

# ---------------------------------------------------------------------------
# Alert dispatcher — logs + optional Slack, with cooldown
# ---------------------------------------------------------------------------
alert() {
    local severity="$1"   # WARN or CRIT
    local check="$2"
    local detail="$3"
    local cooldown_key="${check// /_}_${severity}"

    if [[ "$severity" == "CRIT" ]]; then
        log_crit "$check — $detail"
    else
        log_warn "$check — $detail"
    fi

    if should_alert "$cooldown_key"; then
        send_slack "$severity" "$check" "$detail"
    fi
}

# ---------------------------------------------------------------------------
# Metric collectors
# ---------------------------------------------------------------------------

# Returns integer CPU usage percent averaged over CPU_SAMPLES reads
get_cpu_pct() {
    local total=0
    local i
    for (( i=0; i<CPU_SAMPLES; i++ )); do
        # top -bn1 produces one batch frame; idle% is field 8 of the Cpu(s) line
        local idle
        idle=$(top -bn1 | grep '^%Cpu\|^Cpu' | awk '{print $8}' | tr -d '%,')
        # Fallback: use /proc/stat for 100ms delta
        if [[ -z "$idle" ]]; then
            local stat1 stat2 idle1 idle2 total1 total2
            stat1=$(awk 'NR==1{print $2+$3+$4+$5+$6+$7+$8+$9, $5}' /proc/stat)
            sleep 0.1
            stat2=$(awk 'NR==1{print $2+$3+$4+$5+$6+$7+$8+$9, $5}' /proc/stat)
            total1=$(echo "$stat1" | awk '{print $1}')
            total2=$(echo "$stat2" | awk '{print $1}')
            idle1=$(echo "$stat1" | awk '{print $2}')
            idle2=$(echo "$stat2" | awk '{print $2}')
            local dt=$(( total2 - total1 ))
            local di=$(( idle2  - idle1 ))
            (( dt == 0 )) && idle=100 || idle=$(( di * 100 / dt ))
        fi
        # Round to integer
        idle=${idle%.*}
        total=$(( total + (100 - idle) ))
        (( i < CPU_SAMPLES - 1 )) && sleep 1
    done
    echo $(( total / CPU_SAMPLES ))
}

# Returns integer memory used percent
get_mem_pct() {
    awk '/MemTotal/{total=$2} /MemAvailable/{avail=$2} END{printf "%d", (total-avail)*100/total}' \
        /proc/meminfo
}

# Returns integer disk used percent for DISK_PATH
get_disk_pct() {
    df --output=pcent "$DISK_PATH" 2>/dev/null | tail -1 | tr -d '% '
}

# Returns human-readable used/total for memory
get_mem_detail() {
    awk '/MemTotal/{t=$2} /MemAvailable/{a=$2} END{
        used=(t-a)/1024; total=t/1024;
        printf "%.0fMiB used of %.0fMiB total", used, total
    }' /proc/meminfo
}

# Returns human-readable used/total for disk
get_disk_detail() {
    df -h "$DISK_PATH" | awk 'NR==2{printf "%s used of %s total (%s)", $3, $2, $5}'
}

# ---------------------------------------------------------------------------
# Check runner — compare value to warn/crit thresholds
# ---------------------------------------------------------------------------
check_metric() {
    local name="$1"
    local value="$2"     # integer percent
    local warn="$3"
    local crit="$4"
    local detail="$5"

    if (( value >= crit )); then
        alert "CRIT" "$name at ${value}%" "$detail"
        return 2
    elif (( value >= warn )); then
        alert "WARN" "$name at ${value}%" "$detail"
        return 1
    else
        log_ok "$name ${value}% — $detail"
        return 0
    fi
}

# ---------------------------------------------------------------------------
# Service status check
# ---------------------------------------------------------------------------
check_services() {
    local exit_code=0
    for svc in $SERVICES; do
        if systemctl is-active --quiet "$svc" 2>/dev/null; then
            log_ok "Service $svc is running"
        else
            local state
            state=$(systemctl is-active "$svc" 2>/dev/null || true)
            alert "CRIT" "Service $svc is $state" "Expected: active — run: journalctl -u $svc -n 20"
            exit_code=2
        fi
    done
    return $exit_code
}

# ---------------------------------------------------------------------------
# Report mode — print a tidy summary table and exit
# ---------------------------------------------------------------------------
print_report() {
    local cpu mem disk
    cpu=$(get_cpu_pct)
    mem=$(get_mem_pct)
    disk=$(get_disk_pct)
    local mem_detail disk_detail
    mem_detail=$(get_mem_detail)
    disk_detail=$(get_disk_detail)

    echo ""
    echo "╔══════════════════════════════════════════════════════╗"
    echo "║  MiniPlatform health report — $(_timestamp)  ║"
    echo "╠══════════════════════════════════════════════════════╣"
    printf "║  %-12s %3d%%   (warn %-2s%%  crit %-2s%%)         ║\n" \
        "CPU" "$cpu" "$CPU_WARN_PCT" "$CPU_CRIT_PCT"
    printf "║  %-12s %3d%%   (warn %-2s%%  crit %-2s%%)         ║\n" \
        "Memory" "$mem" "$MEM_WARN_PCT" "$MEM_CRIT_PCT"
    printf "║  %-12s %3d%%   (warn %-2s%%  crit %-2s%%)         ║\n" \
        "Disk ($DISK_PATH)" "$disk" "$DISK_WARN_PCT" "$DISK_CRIT_PCT"
    echo "╠══════════════════════════════════════════════════════╣"
    printf "║  Memory:  %-43s║\n" "$mem_detail"
    printf "║  Disk:    %-43s║\n" "$disk_detail"
    echo "╠══════════════════════════════════════════════════════╣"
    for svc in $SERVICES; do
        local state icon
        if systemctl is-active --quiet "$svc" 2>/dev/null; then
            state="active"; icon="✓"
        else
            state=$(systemctl is-active "$svc" 2>/dev/null || echo "unknown")
            icon="✗"
        fi
        printf "║  %s %-8s  %-39s║\n" "$icon" "$svc" "$state"
    done
    echo "╚══════════════════════════════════════════════════════╝"
    echo ""
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    if [[ "$REPORT_MODE" == true ]]; then
        print_report
        exit 0
    fi

    log_info "--- health check start (host: $HOSTNAME_LABEL) ---"

    local overall_exit=0

    # CPU
    local cpu_pct
    cpu_pct=$(get_cpu_pct)
    check_metric "CPU" "$cpu_pct" "$CPU_WARN_PCT" "$CPU_CRIT_PCT" \
        "averaged over ${CPU_SAMPLES}s" || overall_exit=$?

    # Memory
    local mem_pct mem_detail
    mem_pct=$(get_mem_pct)
    mem_detail=$(get_mem_detail)
    check_metric "Memory" "$mem_pct" "$MEM_WARN_PCT" "$MEM_CRIT_PCT" \
        "$mem_detail" || overall_exit=$?

    # Disk
    local disk_pct disk_detail
    disk_pct=$(get_disk_pct)
    disk_detail=$(get_disk_detail)
    check_metric "Disk ($DISK_PATH)" "$disk_pct" "$DISK_WARN_PCT" "$DISK_CRIT_PCT" \
        "$disk_detail" || overall_exit=$?

    # Services
    check_services || overall_exit=$?

    log_info "--- health check end (exit $overall_exit) ---"
    exit "$overall_exit"
}

main
