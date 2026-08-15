#!/usr/bin/env bash
# Best-effort LOCAL safety net: schedules 99-destroy-all.sh to run automatically
# after $ODCR_HOURS hours via the system `at` daemon.
#
# THIS IS NOT A SUBSTITUTE FOR:
#   - The ODCR's own --end-date-type limited expiry (docs/COST.md) — that's the
#     real cost backstop, enforced by AWS regardless of what your laptop is doing.
#   - Actually watching the clock yourself.
#
# This only fires if your machine stays powered on, awake, and online for the
# full duration, and if the `atd` service is running (macOS: `sudo launchctl
# load -w /System/Library/LaunchDaemons/com.apple.atrun.plist` if `at` jobs
# aren't firing; Linux: `systemctl status atd`). Treat it as a convenience,
# not a guarantee.
set -euo pipefail
cd "$(dirname "$0")"
source lib/env.sh

command -v at >/dev/null 2>&1 || die "'at' command not found. Install it, or just set a phone/calendar alarm for ${ODCR_HOURS}h from now and run ./99-destroy-all.sh manually."

LOG_FILE="${REPO_ROOT}/.deploy/auto-destroy.log"
mkdir -p "$(dirname "$LOG_FILE")"

log "Scheduling ./99-destroy-all.sh to run in ${ODCR_HOURS} hours via 'at'..."
echo "cd '${REPO_ROOT}/scripts' && ./99-destroy-all.sh >> '${LOG_FILE}' 2>&1" | at now + "${ODCR_HOURS}" hours

log "Scheduled. Check pending jobs with: atq"
log "Cancel with: atrm <job-number>"
log "Output will be logged to: ${LOG_FILE}"
warn "Reminder: this only helps if your machine stays on. The ODCR's own --end-date-type limited (docs/COST.md) is the real safety net."
