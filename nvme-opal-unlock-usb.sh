#!/usr/bin/env bash
#
# nvme-opal-unlock-usb.sh
#
# Unlocks TCG Opal 2.0 self-encrypting NVMe drives using the `nvme sed`
# plugin from linux-nvme/nvme-cli (https://github.com/linux-nvme/nvme-cli).
#
# This is a variant of nvme-opal-unlock.sh that adds support for unlocking
# from a USB key device. If a USB unlock device is mounted at a fixed path
# (default: /dev/usb-unlock) and contains a plaintext key file (default:
# unlock.key) whose first line is the Opal passphrase, the script will try
# that passphrase first for each locked drive. On any USB-key failure it
# reports the failure (terminal + log) and falls back to the normal
# interactive prompt flow.
#
# Behavior:
#   * Enumerates NVMe namespace devices via `nvme list`.
#   * For each locked drive, if a USB unlock key is present, attempts to
#     unlock with the key file first; on failure, reports it and falls back.
#   * Prompts for an unlock passphrase for the first drive that requires one.
#   * Automatically rolls a successful passphrase forward to subsequent drives.
#   * On rollover failure, notifies the user and re-prompts for that drive,
#     then continues the rollover with whatever passphrase eventually worked.
#   * After MAX_ATTEMPTS failed manual entries on a single drive, offers
#     [r]etry / [s]kip / [a]bort.
#   * Writes a timestamped log file next to this script.
#
# Requirements:
#   * Linux, run as root.
#   * nvme-cli with the `sed` plugin (>= ~1.16).
#   * `expect` (used to drive nvme's interactive getpass() prompt).
#   * bash >= 4.0.
#
# Exit codes:
#   0  all detected SED drives unlocked (or already unlocked / non-SED)
#   1  one or more drives failed or were skipped
#   2  no NVMe devices found
#   64 invalid CLI arguments
#   other  preflight failure
#

set -uo pipefail

############################
# Bash version gate
############################

if (( BASH_VERSINFO[0] < 4 )); then
    echo "ERROR: bash >= 4.0 required (detected: $BASH_VERSION)" >&2
    exit 1
fi

############################
# Configuration
############################

readonly SCRIPT_NAME="$(basename "$0")"
# Resolve script directory, following symlinks where possible.
if command -v readlink >/dev/null 2>&1 && readlink -f / >/dev/null 2>&1; then
    readonly SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
else
    readonly SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
fi
readonly TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
readonly LOG_FILE="${SCRIPT_DIR}/nvme-opal-unlock-${TIMESTAMP}.log"

readonly MAX_ATTEMPTS="${MAX_ATTEMPTS:-3}"
readonly NVME_BIN="${NVME_BIN:-nvme}"
readonly EXPECT_BIN="${EXPECT_BIN:-expect}"
readonly EXPECT_TIMEOUT="${EXPECT_TIMEOUT:-30}"

# USB unlock-key configuration.
#   USB_UNLOCK_MOUNT : directory where the USB unlock device is mounted.
#   USB_KEY_FILE     : name of the plaintext key file at that mount point.
# The first line of USB_KEY_PATH is used as the Opal passphrase.
readonly USB_UNLOCK_MOUNT="${USB_UNLOCK_MOUNT:-/dev/usb-unlock}"
readonly USB_KEY_FILE="${USB_KEY_FILE:-unlock.key}"
readonly USB_KEY_PATH="${USB_UNLOCK_MOUNT%/}/${USB_KEY_FILE}"

############################
# Terminal styling
############################

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    readonly C_RED=$'\033[0;31m'
    readonly C_GREEN=$'\033[0;32m'
    readonly C_YELLOW=$'\033[0;33m'
    readonly C_BLUE=$'\033[0;34m'
    readonly C_BOLD=$'\033[1m'
    readonly C_RESET=$'\033[0m'
else
    readonly C_RED=''
    readonly C_GREEN=''
    readonly C_YELLOW=''
    readonly C_BLUE=''
    readonly C_BOLD=''
    readonly C_RESET=''
fi

############################
# State
############################

VERBOSE=1
TOTAL_DRIVES=0
UNLOCKED_DRIVES=0
SKIPPED_DRIVES=0
FAILED_DRIVES=0
declare -a UNLOCK_RESULTS=()

############################
# Logging
############################

# File log always includes timestamp + level; terminal output is colorized.
_log_file() {
    local level="$1"; shift
    printf '[%s] [%-5s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$*" >> "$LOG_FILE"
}

log_info()  { _log_file "INFO"  "$*"; printf '%s[INFO]%s %s\n'  "$C_GREEN"  "$C_RESET" "$*"; }
log_warn()  { _log_file "WARN"  "$*"; printf '%s[WARN]%s %s\n'  "$C_YELLOW" "$C_RESET" "$*" >&2; }
log_error() { _log_file "ERROR" "$*"; printf '%s[ERROR]%s %s\n' "$C_RED"    "$C_RESET" "$*" >&2; }
log_debug() {
    _log_file "DEBUG" "$*"
    [[ $VERBOSE -ge 1 ]] && printf '%s[DEBUG]%s %s\n' "$C_BLUE" "$C_RESET" "$*"
}
log_step()  {
    _log_file "STEP" "$*"
    printf '\n%s==>%s %s%s%s\n' "${C_BOLD}${C_BLUE}" "$C_RESET" "$C_BOLD" "$*" "$C_RESET"
}

############################
# Cleanup / signal handling
############################

cleanup() {
    local rc=$?
    # Scrub any lingering passphrase env vars.
    unset NVME_OPAL_PASS NVME_OPAL_DEVICE NVME_OPAL_NVME NVME_OPAL_TIMEOUT 2>/dev/null || true
    _log_file "EXIT" "Exiting with status $rc"
    return $rc
}
trap cleanup EXIT
trap 'log_warn "Interrupted by signal — aborting."; exit 130' INT TERM

############################
# Initialize Log File
############################

init_log() {
    : > "$LOG_FILE" || { echo "ERROR: cannot write log file: $LOG_FILE" >&2; exit 1; }
    chmod 600 "$LOG_FILE" 2>/dev/null || true
    {
        echo ""
        echo "================================================================"
        echo " Started : $(date -Iseconds 2>/dev/null || date)"
        echo " Host    : $(hostname 2>/dev/null || echo unknown)"
        echo " Kernel  : $(uname -srm 2>/dev/null || echo unknown)"
        echo " User    : $(id -un 2>/dev/null) (uid=$(id -u))"
        echo " Script  : ${SCRIPT_DIR}/${SCRIPT_NAME}"
        echo " Bash    : $BASH_VERSION"
        echo "================================================================"
        echo ""
    } >> "$LOG_FILE"
}

############################
# System Requirements Check
############################

require_tool() {
    local tool="$1" pkg_hint="$2"
    if ! command -v "$tool" >/dev/null 2>&1; then
        log_error "Required tool not found: '$tool' ($pkg_hint)"
        return 1
    fi
    log_debug "Found tool: $tool -> $(command -v "$tool")"
    return 0
}

preflight() {
    log_step "System requirement checks"

    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root (current uid=$EUID). Try: sudo $SCRIPT_NAME"
        exit 1
    fi
    log_debug "Running as root."

    if [[ "$(uname -s)" != "Linux" ]]; then
        log_warn "Non-Linux platform detected ($(uname -s)). nvme-cli is Linux-only; continuing for diagnostic purposes."
    fi

    require_tool "$NVME_BIN"   "install via: apt install nvme-cli  /  dnf install nvme-cli" || exit 1
    require_tool "$EXPECT_BIN" "install via: apt install expect    /  dnf install expect"   || exit 1

    # Probe the sed plugin. Different nvme-cli builds expose `help sed` vs `sed --help`.
    if ! "$NVME_BIN" sed --help >/dev/null 2>&1 && ! "$NVME_BIN" help sed >/dev/null 2>&1; then
        log_warn "The 'sed' subcommand does not appear to be present in this nvme-cli build."
        log_warn "Unlock attempts will likely fail. Consider upgrading nvme-cli or building with sed-opal support."
    else
        log_debug "nvme-cli 'sed' plugin is available."
    fi

    local nvme_ver
    nvme_ver="$("$NVME_BIN" version 2>&1 | head -n1 || true)"
    log_info "nvme-cli version: ${nvme_ver:-unknown}"

    local expect_ver
    expect_ver="$("$EXPECT_BIN" -v 2>&1 | head -n1 || true)"
    log_info "expect version  : ${expect_ver:-unknown}"
}

############################
# Device enumeration
############################

enumerate_devices() {
    local -a devs=()

    # Preferred: JSON list. Try jq first, then a minimal sed/grep parser.
    if "$NVME_BIN" list -o json >/dev/null 2>&1; then
        if command -v jq >/dev/null 2>&1; then
            mapfile -t devs < <("$NVME_BIN" list -o json 2>/dev/null \
                | jq -r '.Devices[]?.DevicePath // empty' 2>/dev/null \
                | sort -u)
        else
            mapfile -t devs < <("$NVME_BIN" list -o json 2>/dev/null \
                | grep -oE '"DevicePath"[[:space:]]*:[[:space:]]*"[^"]+"' \
                | sed -E 's/.*"DevicePath"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/' \
                | sort -u)
        fi
    fi

    # Fallback: plain text output.
    if [[ ${#devs[@]} -eq 0 ]]; then
        mapfile -t devs < <("$NVME_BIN" list 2>/dev/null \
            | awk '/^\/dev\/nvme/ {print $1}' \
            | sort -u)
    fi

    # Last-resort fallback: glob /dev for namespace devices.
    if [[ ${#devs[@]} -eq 0 ]]; then
        local g
        for g in /dev/nvme*n1; do
            [[ -b "$g" ]] && devs+=("$g")
        done
    fi

    printf '%s\n' "${devs[@]}"
}

############################
# USB unlock-key support
#
# The USB device is expected to already be mounted as a directory at
# USB_UNLOCK_MOUNT, containing a plaintext key file (USB_KEY_FILE). The first
# line of that file is treated as the Opal passphrase.
############################

# usb_key_available: returns 0 if the USB key file is present and readable.
usb_key_available() {
    [[ -d "$USB_UNLOCK_MOUNT" ]] || return 1
    [[ -f "$USB_KEY_PATH"     ]] || return 1
    [[ -r "$USB_KEY_PATH"     ]] || return 1
    return 0
}

# read_usb_key: prints the passphrase (first line of the key file) on stdout.
# Returns nonzero if the file is missing/unreadable/empty.
read_usb_key() {
    if ! usb_key_available; then
        return 1
    fi

    # Warn (once-ish, it's cheap) if the key file is readable by group/other —
    # a plaintext Opal passphrase should be 0600/0400.
    local perms
    if perms="$(stat -c '%a' "$USB_KEY_PATH" 2>/dev/null)"; then
        if [[ "$perms" =~ [1-7]$ || "$perms" =~ [1-7].$ ]]; then
            log_warn "USB key file $USB_KEY_PATH is group/other-accessible (mode $perms); consider chmod 600."
        fi
    fi

    # Read only the first line. `read` returns nonzero when the line has no
    # trailing newline, but still populates the variable — handle that case.
    local key=""
    IFS= read -r key < "$USB_KEY_PATH" || true
    if [[ -z "$key" ]]; then
        log_warn "USB key file $USB_KEY_PATH is empty or unreadable."
        return 1
    fi
    printf '%s' "$key"
}

############################
# SED discovery
#   0 = drive appears locked (or state unknown — attempt anyway)
#   1 = drive is confirmed unlocked
#   2 = drive does not support SED/Opal
############################

sed_state() {
    local device="$1"
    local out rc

    out="$("$NVME_BIN" sed discover "$device" 2>&1)"
    rc=$?

    if [[ $rc -ne 0 ]]; then
        log_debug "sed discover failed for $device (rc=$rc): $(echo "$out" | tr '\n' ' ' | head -c 400)"
        if echo "$out" | grep -qiE "not supported|invalid argument|no such|not a sed"; then
            return 2
        fi
        return 0
    fi

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        log_debug "discover[$device]: $line"
    done <<< "$out"

    if echo "$out" | grep -qiE "locking[[:space:]_-]*supported[[:space:]]*[:=][[:space:]]*(no|n|0|false)"; then
        return 2
    fi
    if echo "$out" | grep -qiE "locked[[:space:]]*[:=][[:space:]]*(no|n|0|false)"; then
        return 1
    fi
    return 0
}

############################
# Passphrase prompt (reads from /dev/tty so stdin redirection is OK).
############################

prompt_passphrase() {
    local device="$1"
    local pass=""
    {
        printf '%sEnter Opal passphrase for %s:%s ' "$C_BOLD" "$device" "$C_RESET"
    } > /dev/tty
    IFS= read -r -s pass < /dev/tty
    printf '\n' > /dev/tty
    if [[ -z "$pass" ]]; then
        log_warn "Empty passphrase entered for $device."
    fi
    printf '%s' "$pass"
}

############################
# Unlock attempt via expect.
# Returns:
#   0 - unlock succeeded (or drive reported already unlocked)
#   1 - unlock failed (wrong passphrase / Opal error)
#   2 - tool/spawn/timeout failure
############################

attempt_unlock() {
    local device="$1"
    local passphrase="$2"
    local rc output

    log_debug "Spawning: $NVME_BIN sed unlock --ask-key $device"

    # Pass passphrase via env var (not argv) so it doesn't appear in /proc/PID/cmdline.
    # The expect heredoc is single-quoted so bash performs no substitution — expect
    # reads the env vars itself via $env(...).
    output="$(
        NVME_OPAL_PASS="$passphrase" \
        NVME_OPAL_DEVICE="$device" \
        NVME_OPAL_NVME="$NVME_BIN" \
        NVME_OPAL_TIMEOUT="$EXPECT_TIMEOUT" \
        "$EXPECT_BIN" <<'EXPECT_EOF' 2>&1
log_user 1
set timeout $env(NVME_OPAL_TIMEOUT)
set device  $env(NVME_OPAL_DEVICE)
set pass    $env(NVME_OPAL_PASS)
set nvme    $env(NVME_OPAL_NVME)

spawn -noecho $nvme sed unlock --ask-key $device

# Wait for the password prompt.
expect {
    -nocase -re "password|passphrase" {
        send -- "$pass\r"
    }
    timeout {
        puts stderr "EXPECT_TIMEOUT_WAITING_FOR_PROMPT"
        catch {exec kill -TERM [exp_pid]}
        exit 124
    }
    eof {
        # Process exited before prompting — propagate its exit code.
        catch wait result
        exit [lindex $result 3]
    }
}

# Wait for completion.
expect {
    eof { }
    timeout {
        puts stderr "EXPECT_TIMEOUT_AFTER_SEND"
        catch {exec kill -TERM [exp_pid]}
        exit 124
    }
}

catch wait result
exit [lindex $result 3]
EXPECT_EOF
    )"
    rc=$?

    # Mirror nvme's output into the debug log. The passphrase itself is never
    # echoed by getpass() and is not sent through expect's stdout.

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        log_debug "nvme: $line"
    done <<< "$output"

    if [[ $rc -eq 0 ]]; then
        return 0
    elif [[ $rc -eq 124 ]]; then
        log_error "Timeout waiting for nvme sed unlock on $device (>${EXPECT_TIMEOUT}s)."
        return 2
    else
        # Some nvme-cli builds return nonzero with a clear "already unlocked" message.
        if echo "$output" | grep -qiE "already[[:space:]]+(unlocked|disabled)|not[[:space:]]+locked|locking[[:space:]]+not[[:space:]]+enabled"; then
            log_info "Drive $device reports already unlocked."
            return 0
        fi
        log_debug "nvme sed unlock returned rc=$rc on $device"
        return 1
    fi
}

############################
# Per-drive unlock loop.
# Uses an indirect reference to the rolling passphrase variable so a successful
# unlock can roll forward to the next drive.
# Returns:
#   0 - drive unlocked
#   1 - drive skipped (tool error, user skip)
#   2 - user aborted the whole run
############################

unlock_drive() {
    local device="$1"
    local pass_ref="$2"
    local pass="${!pass_ref}"
    local rc

    # Step 1: if a USB unlock key is present, try it first.
    if usb_key_available; then
        local usb_pass=""
        if usb_pass="$(read_usb_key)"; then
            log_info "USB unlock key detected at $USB_KEY_PATH — attempting to unlock $device."
            if attempt_unlock "$device" "$usb_pass"; then
                log_info "${C_GREEN}Unlocked${C_RESET} $device using USB key file."
                # Roll the working passphrase forward to subsequent drives.
                printf -v "$pass_ref" '%s' "$usb_pass"
                usb_pass=""
                return 0
            fi
            rc=$?
            usb_pass=""
            if [[ $rc -eq 2 ]]; then
                log_error "Tool error on $device while using USB key — skipping."
                return 1
            fi
            log_warn "USB key file did not unlock $device — falling back to manual entry."
        else
            log_warn "USB unlock device present but key file could not be read ($USB_KEY_PATH) — falling back to manual entry."
        fi
    fi

    # Step 2: try the carried passphrase from the previous drive as a free attempt.
    if [[ -n "$pass" ]]; then
        log_info "Trying carried passphrase on $device..."
        if attempt_unlock "$device" "$pass"; then
            log_info "${C_GREEN}Unlocked${C_RESET} $device with carried passphrase."
            printf -v "$pass_ref" '%s' "$pass"
            return 0
        fi
        rc=$?
        if [[ $rc -eq 2 ]]; then
            log_error "Tool error on $device — skipping."
            return 1
        fi
        log_warn "Carried passphrase did not unlock $device. Prompting for new passphrase."
    fi

    # Step 3: interactive prompt loop.
    local attempt=0
    while : ; do
        attempt=$((attempt + 1))
        pass="$(prompt_passphrase "$device")"

        if attempt_unlock "$device" "$pass"; then
            log_info "${C_GREEN}Unlocked${C_RESET} $device on attempt $attempt."
            # Roll this passphrase forward to subsequent drives.
            printf -v "$pass_ref" '%s' "$pass"
            return 0
        fi
        rc=$?
        if [[ $rc -eq 2 ]]; then
            log_error "Tool error on $device — skipping."
            return 1
        fi

        log_warn "Passphrase did not unlock $device (attempt $attempt/$MAX_ATTEMPTS)."

        if (( attempt >= MAX_ATTEMPTS )); then
            local choice=""
            {
                printf '\n%s%d failed attempts on %s.%s\n' "$C_YELLOW" "$attempt" "$device" "$C_RESET"
                printf '%s[r]etry / [s]kip drive / [a]bort run [r]:%s ' "$C_BOLD" "$C_RESET"
            } > /dev/tty
            IFS= read -r choice < /dev/tty
            case "${choice,,}" in
                ""|r|retry)
                    log_info "User chose to keep retrying on $device."
                    attempt=0
                    ;;
                s|skip)
                    log_warn "User chose to skip $device."
                    return 1
                    ;;
                a|abort)
                    log_error "User chose to abort the run."
                    return 2
                    ;;
                *)
                    log_warn "Unrecognized choice '$choice' — continuing to retry."
                    attempt=0
                    ;;
            esac
        fi
    done
}

############################
# Help
############################

usage() {
    cat <<USAGE
$SCRIPT_NAME — Unlock TCG Opal 2.0 NVMe drives via nvme-cli (with USB-key support)

USAGE:
    sudo $SCRIPT_NAME [options]

OPTIONS:
    -v, --verbose   Verbose terminal output (default)
    -q, --quiet     Suppress DEBUG lines on terminal (still written to log file)
    -h, --help      Show this help

USB UNLOCK KEY:
    If a USB unlock device is mounted at USB_UNLOCK_MOUNT and contains the key
    file USB_KEY_FILE, the first line of that file is tried first for each
    locked drive. On any failure the script reports it and falls back to the
    interactive passphrase prompt.
        Key file: ${USB_KEY_PATH}

ENVIRONMENT:
    NVME_BIN          Path to nvme binary               (default: nvme)
    EXPECT_BIN        Path to expect binary             (default: expect)
    EXPECT_TIMEOUT    Seconds to wait per stage         (default: 30)
    MAX_ATTEMPTS      Manual entries before [r/s/a]     (default: 3)
    USB_UNLOCK_MOUNT  USB unlock mount point            (default: /dev/usb-unlock)
    USB_KEY_FILE      Key file name at that mount       (default: unlock.key)
    NO_COLOR          If set, disable terminal colors

LOG:
    A timestamped log file is created next to the script:
        ${LOG_FILE}

EXIT CODES:
    0   all SED drives unlocked (or already unlocked / non-SED)
    1   one or more drives failed or were skipped
    2   no NVMe devices detected
    64  invalid arguments
USAGE
}

############################
# Main
############################
main() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -v|--verbose) VERBOSE=1; shift ;;
            -q|--quiet)   VERBOSE=0; shift ;;
            -h|--help)    usage; exit 0 ;;
            --)           shift; break ;;
            *)
                echo "ERROR: unknown argument: $1" >&2
                usage >&2
                exit 64
                ;;
        esac
    done

    init_log
    log_info "Log file: $LOG_FILE"
    preflight

    # Report USB unlock-key availability up front (re-checked per drive).
    if usb_key_available; then
        log_info "USB unlock key found at $USB_KEY_PATH — will try it first for each locked drive."
    else
        log_debug "No USB unlock key at $USB_KEY_PATH — interactive prompts only."
    fi

    log_step "Enumerating NVMe devices"
    local -a devices
    mapfile -t devices < <(enumerate_devices)
    TOTAL_DRIVES=${#devices[@]}

    if (( TOTAL_DRIVES == 0 )); then
        log_error "No NVMe devices detected."
        exit 2
    fi

    log_info "Detected $TOTAL_DRIVES NVMe device(s):"
    local d
    for d in "${devices[@]}"; do
        log_info "  - $d"
    done

    # Rolling passphrase, carried across drives. Local to main() so it is freed
    # when the function returns.
    local rolling_pass=""

    local i=0
    local device st urc
    for device in "${devices[@]}"; do
        i=$((i + 1))
        log_step "[$i/$TOTAL_DRIVES] $device"

        sed_state "$device"; st=$?
        case $st in
            1)
                log_info "$device is already unlocked — skipping."
                SKIPPED_DRIVES=$((SKIPPED_DRIVES + 1))
                UNLOCK_RESULTS+=("$device: ALREADY_UNLOCKED")
                continue
                ;;
            2)
                log_info "$device does not appear to be an Opal/SED drive — skipping."
                SKIPPED_DRIVES=$((SKIPPED_DRIVES + 1))
                UNLOCK_RESULTS+=("$device: NOT_SED")
                continue
                ;;
            *) : ;;  # 0 = locked or unknown, proceed
        esac

        unlock_drive "$device" rolling_pass; urc=$?
        case $urc in
            0)
                UNLOCKED_DRIVES=$((UNLOCKED_DRIVES + 1))
                UNLOCK_RESULTS+=("$device: UNLOCKED")
                ;;
            1)
                FAILED_DRIVES=$((FAILED_DRIVES + 1))
                UNLOCK_RESULTS+=("$device: SKIPPED_OR_ERROR")
                # Drop the rolling passphrase — it clearly doesn't apply here,
                # and we don't know whether the next drive shares it with the
                # one we just skipped or with the most recently unlocked one.
                # We keep the rolling value as-is: still the last successful pass.
                ;;
            2)
                FAILED_DRIVES=$((FAILED_DRIVES + 1))
                UNLOCK_RESULTS+=("$device: ABORTED")
                log_error "Aborting remaining drives."
                break
                ;;
        esac
    done

    # Wipe the rolling passphrase from this shell's memory as best we can.
    rolling_pass=""
    unset rolling_pass

    log_step "Summary"
    log_info "Total devices    : $TOTAL_DRIVES"
    log_info "Unlocked         : $UNLOCKED_DRIVES"
    log_info "Skipped/Not-SED  : $SKIPPED_DRIVES"
    log_info "Failed/Aborted   : $FAILED_DRIVES"
    local r
    for r in "${UNLOCK_RESULTS[@]}"; do
        log_info "  $r"
    done
    log_info "Full log: $LOG_FILE"

    if (( FAILED_DRIVES > 0 )); then
        exit 1
    fi
    exit 0
}

main "$@"
