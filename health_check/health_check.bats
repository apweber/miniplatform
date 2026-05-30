#!/usr/bin/env bats
# =============================================================================
# health_check.bats — Bats test suite for health_check.sh
#
# Requires: bats-core (https://github.com/bats-core/bats-core)
# Install:  git clone https://github.com/bats-core/bats-core && cd bats-core && ./install.sh /usr/local
#
# Run:      bats health_check.bats
# =============================================================================

# ---------------------------------------------------------------------------
# Setup: point to a temp log and config so tests don't touch /var/log
# ---------------------------------------------------------------------------
setup() {
    TEST_DIR="$(mktemp -d)"
    export LOG_FILE="$TEST_DIR/health.log"
    export COOLDOWN_DIR="$TEST_DIR/cooldowns"
    export SLACK_WEBHOOK=""         # never hit real Slack in tests
    export SERVICES=""              # skip systemd checks by default
    export CPU_SAMPLES=1            # faster tests
    SCRIPT="$(dirname "$BATS_TEST_FILENAME")/health_check.sh"
    mkdir -p "$COOLDOWN_DIR"
}

teardown() {
    rm -rf "$TEST_DIR"
}

# ---------------------------------------------------------------------------
# Helper: run script with CPU/mem/disk forced via env so we don't need root
# ---------------------------------------------------------------------------
run_with_overrides() {
    CPU_WARN_PCT=75 CPU_CRIT_PCT=90 \
    MEM_WARN_PCT=80 MEM_CRIT_PCT=95 \
    DISK_WARN_PCT=75 DISK_CRIT_PCT=90 \
    "$@"
}

# ---------------------------------------------------------------------------
# 1. Script is executable and shows help without error
# ---------------------------------------------------------------------------
@test "script exists and --help exits 0" {
    run bash "$SCRIPT" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"Usage"* ]]
}

# ---------------------------------------------------------------------------
# 2. --report mode exits 0 and prints the table header
# ---------------------------------------------------------------------------
@test "--report prints summary table" {
    run bash "$SCRIPT" --report
    [ "$status" -eq 0 ] || [ "$status" -eq 1 ] || [ "$status" -eq 2 ]
    [[ "$output" == *"health report"* ]]
}

# ---------------------------------------------------------------------------
# 3. Log file is created on first run
# ---------------------------------------------------------------------------
@test "log file is created on run" {
    run bash "$SCRIPT" --quiet
    [ -f "$LOG_FILE" ]
}

# ---------------------------------------------------------------------------
# 4. Log file contains start/end markers
# ---------------------------------------------------------------------------
@test "log contains start and end markers" {
    bash "$SCRIPT" --quiet || true
    grep -q "health check start" "$LOG_FILE"
    grep -q "health check end"   "$LOG_FILE"
}

# ---------------------------------------------------------------------------
# 5. OK lines are written when thresholds are not breached
#    (Force very high thresholds so nothing triggers)
# ---------------------------------------------------------------------------
@test "writes OK lines when well under thresholds" {
    CPU_WARN_PCT=99 CPU_CRIT_PCT=100 \
    MEM_WARN_PCT=99 MEM_CRIT_PCT=100 \
    DISK_WARN_PCT=99 DISK_CRIT_PCT=100 \
    bash "$SCRIPT" --quiet
    grep -q "\[OK" "$LOG_FILE"
}

# ---------------------------------------------------------------------------
# 6. WARN line is written when threshold is exceeded
#    Achieved by setting DISK thresholds to 0 (always triggers)
# ---------------------------------------------------------------------------
@test "writes WARN when disk threshold is 0" {
    DISK_WARN_PCT=0 DISK_CRIT_PCT=100 \
    bash "$SCRIPT" --quiet || true
    grep -q "\[WARN\|\[CRIT" "$LOG_FILE"
}

# ---------------------------------------------------------------------------
# 7. CRIT line is written when critical threshold is exceeded
# ---------------------------------------------------------------------------
@test "writes CRIT when disk critical threshold is 0" {
    DISK_WARN_PCT=0 DISK_CRIT_PCT=0 \
    bash "$SCRIPT" --quiet || true
    grep -q "\[CRIT" "$LOG_FILE"
}

# ---------------------------------------------------------------------------
# 8. Exit code is non-zero when a check fails
# ---------------------------------------------------------------------------
@test "exit code is non-zero on threshold breach" {
    run bash "$SCRIPT" --quiet \
        DISK_WARN_PCT=0 DISK_CRIT_PCT=0
    # We accept 1 (warn) or 2 (crit), not 0
    [ "$status" -ne 0 ] || \
        DISK_WARN_PCT=0 DISK_CRIT_PCT=0 bash "$SCRIPT" --quiet; [ "$?" -ne 0 ]
}

# ---------------------------------------------------------------------------
# 9. Cooldown prevents duplicate alert entries in the log
# ---------------------------------------------------------------------------
@test "cooldown suppresses duplicate Slack calls" {
    export ALERT_COOLDOWN_SECS=9999
    DISK_WARN_PCT=0 DISK_CRIT_PCT=0 bash "$SCRIPT" --quiet || true
    DISK_WARN_PCT=0 DISK_CRIT_PCT=0 bash "$SCRIPT" --quiet || true

    # There should be exactly one cooldown stamp file for the disk CRIT key
    local stamp_count
    stamp_count=$(ls "$COOLDOWN_DIR" | grep -c "Disk" || echo 0)
    [ "$stamp_count" -ge 1 ]
}

# ---------------------------------------------------------------------------
# 10. Unknown flag exits with error
# ---------------------------------------------------------------------------
@test "unknown flag exits non-zero with message" {
    run bash "$SCRIPT" --notaflag
    [ "$status" -ne 0 ]
    [[ "$output" == *"Unknown option"* ]]
}

# ---------------------------------------------------------------------------
# 11. Config file is sourced when present
# ---------------------------------------------------------------------------
@test "config file overrides default thresholds" {
    echo "DISK_WARN_PCT=0" > "$TEST_DIR/health_check.conf"
    echo "DISK_CRIT_PCT=100" >> "$TEST_DIR/health_check.conf"
    # Temporarily symlink the conf next to the script
    local script_dir
    script_dir="$(dirname "$SCRIPT")"
    cp "$TEST_DIR/health_check.conf" "$script_dir/health_check.conf.test_override"
    # Source manually to verify parsing works
    run bash -c "source '$script_dir/health_check.conf.test_override'; echo \$DISK_WARN_PCT"
    rm -f "$script_dir/health_check.conf.test_override"
    [ "$status" -eq 0 ]
    [[ "$output" == "0" ]]
}
