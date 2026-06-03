#!/bin/bash
#
# Focused DEBUG diagnostics compatibility checks for rp-cli-debug against a launched
# RepoPrompt debug app on the BombSquad workspace.
#
# Usage: ./test-debug-transport-bombsquad.sh [--verbose] [--section <name>]
# Sections: prereq, schema, hidden, raw, proxy, stall, cleanup, ownership, reboot-basic, reboot-binding, reboot, reboot-all, reboot-host, all
#

set -euo pipefail

run_with_timeout() {
    local timeout_secs="$1"
    shift
    perl -e 'alarm shift; exec @ARGV' "$timeout_secs" "$@"
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DRIVER_PATH="$SCRIPT_DIR/debug_proxy_driver.py"
BOMBSQUAD_PATH="${BOMBSQUAD_PATH:-$HOME/Documents/Git/BombSquad}"
WORKSPACE_NAME="BombSquad"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-30}"
DRIVER_TIMEOUT_SECONDS="${DRIVER_TIMEOUT_SECONDS:-12}"
WINDOW_ID="${WINDOW_ID:-1}"
SOCKET_PATH="/tmp/repoprompt-mcp-$(id -u)/repoprompt-D-6.sock"
HIDDEN_TOOL="__repoprompt_debug_diagnostics"

CLI_PATH="${REPOPROMPT_CLI_DEBUG:-}"
if [[ -z "$CLI_PATH" || ! -x "$CLI_PATH" ]]; then
    CLI_PATH="${RP_CLI_DEBUG:-}"
fi
if [[ -z "$CLI_PATH" || ! -x "$CLI_PATH" ]]; then
    CLI_PATH="${REPOPROMPT_CLI:-}"
fi
if [[ -z "$CLI_PATH" || ! -x "$CLI_PATH" ]]; then
    if command -v rp-cli-debug >/dev/null 2>&1; then
        CLI_PATH="$(command -v rp-cli-debug)"
    elif command -v repoprompt-mcp >/dev/null 2>&1; then
        CLI_PATH="$(command -v repoprompt-mcp)"
    fi
fi
if [[ -z "$CLI_PATH" || ! -x "$CLI_PATH" ]]; then
    for path in \
        "$REPO_ROOT/DerivedData/RepoPrompt/Build/Products/Debug/repoprompt-mcp" \
        "$REPO_ROOT/DerivedData/RepoPrompt/Build/Products/Debug/Repo Prompt.app/Contents/MacOS/repoprompt-mcp"
    do
        if [[ -x "$path" ]]; then
            CLI_PATH="$path"
            break
        fi
    done
fi

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

TESTS_PASSED=0
TESTS_FAILED=0
TESTS_SKIPPED=0
SCENARIO_SUMMARY_LINES=""
VERBOSE=false
RUN_SECTION="all"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --verbose|-v)
            VERBOSE=true
            shift
            ;;
        --section|-s)
            RUN_SECTION="$2"
            shift 2
            ;;
        *)
            echo "Unknown argument: $1" >&2
            exit 2
            ;;
    esac
done

log_header() {
    echo ""
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}  $1${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

log_test() { echo -e "${YELLOW}▶ TEST:${NC} $1"; }
log_pass() { echo -e "${GREEN}✓ PASS:${NC} $1"; ((++TESTS_PASSED)); }
log_fail() { echo -e "${RED}✗ FAIL:${NC} $1"; ((++TESTS_FAILED)); }
log_skip() { echo -e "${YELLOW}○ SKIP:${NC} $1"; ((++TESTS_SKIPPED)); }
log_verbose() { if $VERBOSE; then echo -e "  ${BLUE}→${NC} $1"; fi; }
log_output() {
    local output="$1"
    local label="${2:-OUTPUT}"
    echo -e "  ${CYAN}${label}:${NC} ${output:0:1000}"
}

log_verbose_output() {
    local output="$1"
    local label="${2:-OUTPUT}"
    if $VERBOSE; then log_output "$output" "$label"; fi
}

run_cli() {
    run_with_timeout "$TIMEOUT_SECONDS" "$CLI_PATH" "$@" 2>&1 || true
}

run_cli_status() {
    local output
    local rc=0
    output="$(run_with_timeout "$TIMEOUT_SECONDS" "$CLI_PATH" "$@" 2>&1)" || rc=$?
    printf '%s\nEXIT_CODE:%s\n' "$output" "$rc"
}

assert_contains() {
    local output="$1"
    local expected="$2"
    local name="$3"
    if grep -qF -- "$expected" <<< "$output"; then
        log_pass "$name"
    else
        log_fail "$name (expected '$expected')"
        log_output "$output"
    fi
}

assert_not_contains() {
    local output="$1"
    local unexpected="$2"
    local name="$3"
    if grep -qF -- "$unexpected" <<< "$output"; then
        log_fail "$name (unexpected '$unexpected')"
        log_output "$output"
    else
        log_pass "$name"
    fi
}

assert_json_check() {
    local output="$1"
    local name="$2"
    local code="$3"
    if python3 -c "$code" <<< "$output" >/dev/null 2>&1; then
        log_pass "$name"
    else
        log_fail "$name"
        log_output "$output"
    fi
}

assert_hidden_ok() {
    local output="$1"
    local name="$2"
    assert_json_check "$output" "$name" '
import json,sys
obj=json.load(sys.stdin)
assert obj.get("ok") is True, obj
assert obj.get("op") == "ping", obj
assert isinstance(obj.get("connection_id"), str) and len(obj["connection_id"]) >= 32, obj
'
}

run_driver() {
    local scenario="$1"
    shift || true
    local rc=0
    local stdout_file stderr_file output stderr_output summary
    stdout_file="$(mktemp /tmp/repoprompt-debug-driver-stdout.XXXXXX)"
    stderr_file="$(mktemp /tmp/repoprompt-debug-driver-stderr.XXXXXX)"
    log_test "raw proxy driver scenario: $scenario"
    if $VERBOSE; then
        python3 "$DRIVER_PATH" --cli "$CLI_PATH" --scenario "$scenario" --timeout "$DRIVER_TIMEOUT_SECONDS" --window-id "$WINDOW_ID" --verbose "$@" >"$stdout_file" 2>"$stderr_file" || rc=$?
    else
        python3 "$DRIVER_PATH" --cli "$CLI_PATH" --scenario "$scenario" --timeout "$DRIVER_TIMEOUT_SECONDS" --window-id "$WINDOW_ID" "$@" >"$stdout_file" 2>"$stderr_file" || rc=$?
    fi
    output="$(cat "$stdout_file")"
    stderr_output="$(tail -c 2000 "$stderr_file" 2>/dev/null || true)"
    if [[ $rc -eq 0 ]] && python3 -c 'import json,sys; obj=json.load(sys.stdin); assert obj.get("ok") is True' <<< "$output" >/dev/null 2>&1; then
        log_pass "driver $scenario"
        summary="$(python3 -c 'import json,sys; obj=json.load(sys.stdin); details=obj.get("details", {}); bits=[]
if isinstance(details, dict):
    for key in ("responses","batch_ids","parse_code","unknown_code","connection_id","exit_code","response_id","saw_in_flight","before_connection_id","after_connection_id","before_a_connection_id","after_a_connection_id","before_b_connection_id","after_b_connection_id","proxy_pid","proxy_a_pid","proxy_b_pid","session_fingerprint","session_a","session_b","client_name","restart_id","down_ms","reconnect_elapsed_ms","bind_mode","before_binding_kind","after_binding_kind","before_workspace","after_workspace","before_workspace_id","after_workspace_id","before_active_context_id","after_active_context_id","before_active_context_name","after_active_context_name","explicit_context_binding_restored","inflight_response_observed","transparent_without_reinitialize"):
        if key in details:
            bits.append(f"{key}={details[key]}")
print(f"{obj.get('"'"'scenario'"'"')}: " + (", ".join(bits) if bits else "ok"))' <<< "$output")"
        SCENARIO_SUMMARY_LINES+="  - $summary
"
        if $VERBOSE && [[ -n "$stderr_output" ]]; then
            log_output "$stderr_output" "DRIVER STDERR"
        fi
    else
        log_fail "driver $scenario (rc=$rc)"
        log_output "$output" "DRIVER STDOUT"
        if [[ -n "$stderr_output" ]]; then
            log_output "$stderr_output" "DRIVER STDERR"
        fi
    fi
    rm -f "$stdout_file" "$stderr_file"
}

section_prereq() {
    log_header "Prerequisites"

    log_test "CLI executable discovered"
    if [[ -n "$CLI_PATH" && -x "$CLI_PATH" ]]; then
        log_pass "CLI executable discovered: $CLI_PATH"
    else
        log_fail "CLI executable not found; set REPOPROMPT_CLI_DEBUG or RP_CLI_DEBUG"
        return
    fi

    log_test "python3 available"
    if command -v python3 >/dev/null 2>&1; then log_pass "python3 available"; else log_fail "python3 missing"; fi

    log_test "raw proxy driver present"
    if [[ -f "$DRIVER_PATH" ]]; then log_pass "driver present"; else log_fail "driver missing: $DRIVER_PATH"; fi

    log_test "BombSquad path exists"
    if [[ -d "$BOMBSQUAD_PATH" ]]; then log_pass "BombSquad path exists"; else log_fail "BombSquad path missing: $BOMBSQUAD_PATH"; fi

    log_test "RepoPrompt debug app process appears to be running"
    if pgrep -x "Repo Prompt" >/dev/null 2>&1 || pgrep -x "RepoPrompt" >/dev/null 2>&1; then
        log_pass "RepoPrompt app running"
    else
        log_fail "RepoPrompt app is not running; launch the debug app first"
    fi

    log_test "DEBUG bootstrap socket exists"
    if [[ -S "$SOCKET_PATH" ]]; then log_pass "debug socket exists: $SOCKET_PATH"; else log_fail "debug socket missing: $SOCKET_PATH"; fi

    log_test "CLI --version succeeds"
    local version_output
    version_output="$(run_cli --version)"
    if [[ -n "$version_output" ]]; then log_pass "CLI --version produced output"; else log_fail "CLI --version produced no output"; fi
    log_verbose_output "$version_output"

    log_test "hidden debug ping succeeds"
    local ping_output
    ping_output="$(run_cli --call "$HIDDEN_TOOL" --json '{"op":"ping","_rawJSON":true}' --compact)"
    assert_hidden_ok "$ping_output" "hidden debug ping succeeds"

    log_test "window/workspace setup check"
    local workspace_output
    workspace_output="$(run_cli --call bind_context --json "{\"op\":\"list\",\"window_id\":$WINDOW_ID,\"_rawJSON\":true}" --compact)"
    if grep -q "$WORKSPACE_NAME" <<< "$workspace_output" || grep -q '"window_id"[[:space:]]*:[[:space:]]*'"$WINDOW_ID" <<< "$workspace_output" || grep -q '"windowID"[[:space:]]*:[[:space:]]*'"$WINDOW_ID" <<< "$workspace_output"; then
        log_pass "window/workspace setup looks usable"
    else
        log_fail "window $WINDOW_ID does not appear bound to $WORKSPACE_NAME; switch debug app window $WINDOW_ID to BombSquad"
        log_output "$workspace_output"
    fi
}

section_schema() {
    log_header "Schema / non-advertisement"
    local list_output schema_output describe_output
    list_output="$(run_cli --list-tools)"
    schema_output="$(run_cli --tools-schema)"
    describe_output="$(run_cli_status --describe "$HIDDEN_TOOL")"

    assert_not_contains "$list_output" "$HIDDEN_TOOL" "hidden tool absent from --list-tools"
    assert_not_contains "$schema_output" "$HIDDEN_TOOL" "hidden tool absent from --tools-schema"
    assert_json_check "$schema_output" "--tools-schema is valid JSON" 'import json,sys; json.load(sys.stdin)'
    assert_contains "$list_output" "read_file" "read_file still advertised"
    assert_contains "$list_output" "file_search" "file_search still advertised"
    assert_contains "$list_output" "manage_selection" "manage_selection still advertised"
    assert_contains "$list_output" "app_settings" "app_settings still advertised"
    if grep -qiE 'not found|unknown|no tool|not available' <<< "$describe_output"; then
        log_pass "--describe hidden tool is not available"
    elif grep -qiE 'unrecognized|unknown option|invalid option|usage:' <<< "$describe_output"; then
        log_skip "--describe is not supported by this CLI"
    else
        log_fail "--describe hidden tool should report not found/unknown"
        log_output "$describe_output"
    fi
}

section_hidden() {
    log_header "Direct hidden calls"
    local single_output exec_output legacy_output conn_output snapshot_output routing_output history_output diag_output
    single_output="$(run_cli --call "$HIDDEN_TOOL" --json '{"op":"ping","tag":"single-shot","_rawJSON":true}' --compact)"
    assert_hidden_ok "$single_output" "single-shot hidden ping"
    assert_json_check "$single_output" "single-shot tag round-trips" 'import json,sys; obj=json.load(sys.stdin); assert obj.get("tag") == "single-shot", obj'

    exec_output="$(run_cli -e 'call __repoprompt_debug_diagnostics {"op":"ping","tag":"exec"}' --compact)"
    assert_hidden_ok "$exec_output" "exec hidden ping"
    assert_json_check "$exec_output" "exec tag round-trips" 'import json,sys; obj=json.load(sys.stdin); assert obj.get("tag") == "exec", obj'

    legacy_output="$(run_cli -e 'call __repoprompt_debug_transport {"op":"ping","tag":"legacy-alias"}' --compact)"
    assert_hidden_ok "$legacy_output" "legacy alias hidden ping"
    assert_json_check "$legacy_output" "legacy alias tag round-trips" 'import json,sys; obj=json.load(sys.stdin); assert obj.get("tag") == "legacy-alias", obj'

    conn_output="$(run_cli --call "$HIDDEN_TOOL" --json '{"op":"connections","include_identity":true,"_rawJSON":true}' --compact)"
    assert_json_check "$conn_output" "connections hidden op returns JSON" 'import json,sys; obj=json.load(sys.stdin); assert obj.get("ok") is True and isinstance(obj.get("connections"), list), obj'

    snapshot_output="$(run_cli --call "$HIDDEN_TOOL" --json '{"op":"connection_snapshot","_rawJSON":true}' --compact)"
    assert_json_check "$snapshot_output" "connection snapshot hidden op returns JSON" 'import json,sys; obj=json.load(sys.stdin); assert obj.get("ok") is True and obj.get("op") == "connection_snapshot", obj'

    routing_output="$(run_cli --call "$HIDDEN_TOOL" --json '{"op":"routing_snapshot","_rawJSON":true}' --compact)"
    assert_json_check "$routing_output" "routing snapshot hidden op returns JSON" 'import json,sys; obj=json.load(sys.stdin); assert obj.get("ok") is True and obj.get("op") == "routing_snapshot" and "binding" in obj, obj'

    history_output="$(run_cli --call "$HIDDEN_TOOL" --json '{"op":"connection_history","limit":10,"_rawJSON":true}' --compact)"
    assert_json_check "$history_output" "connection history hidden op returns JSON" 'import json,sys; obj=json.load(sys.stdin); assert obj.get("ok") is True and isinstance(obj.get("events"), list), obj'

    diag_output="$(run_cli --call "$HIDDEN_TOOL" --json '{"op":"bootstrap_diagnostics","_rawJSON":true}' --compact)"
    assert_json_check "$diag_output" "bootstrap diagnostics hidden op returns JSON" 'import json,sys; obj=json.load(sys.stdin); assert obj.get("ok") is True and "socket_path" in obj, obj'
}

section_raw() {
    log_header "Raw JSON-RPC compatibility"
    run_driver pipeline
    run_driver batch
    run_driver parse-error
    run_driver notification
    run_driver final-frame-close
    run_driver final-frame-close-delayed
}

section_cleanup() {
    log_header "Cleanup / disconnect behavior"
    run_driver eof-cleanup
    run_driver final-frame-close
    run_driver kill-cleanup
    run_driver close-before-response
}

section_proxy() {
    log_header "Proxy stdout broken pipe"
    run_driver stdout-broken-pipe
}

section_stall() {
    log_header "Proxy stdout stall timeout"
    run_driver stdout-stall --large-bytes 4194304
}

section_ownership() {
    log_header "Disconnect ownership cancellation"
    run_driver ownership
}

section_reboot_basic() {
    log_header "Reconnect / reboot basic"
    run_driver reboot-basic
}

section_reboot_binding() {
    log_header "Reconnect / reboot binding restoration"
    run_driver reboot-with-binding
}

section_reboot() {
    log_header "Reconnect / reboot scenarios"
    run_driver reboot-basic
    run_driver reboot-with-binding
    run_driver reboot-delay
    run_driver reboot-with-inflight
}

section_reboot_all() {
    section_reboot
    run_driver multi-client-reboot
}

section_reboot_host() {
    log_header "Reconnect host-semantics diagnostic"
    run_driver reboot-host-semantics
    if [[ "${EXPECT_TRANSPARENT_RECONNECT:-0}" != "1" ]]; then
        log_skip "transparent reconnect without reinitialize is diagnostic unless EXPECT_TRANSPARENT_RECONNECT=1"
    fi
}

run_section() {
    case "$1" in
        prereq) section_prereq ;;
        schema) section_schema ;;
        hidden) section_hidden ;;
        raw) section_raw ;;
        cleanup) section_cleanup ;;
        proxy) section_proxy ;;
        stall) section_stall ;;
        ownership) section_ownership ;;
        reboot-basic) section_reboot_basic ;;
        reboot-binding) section_reboot_binding ;;
        reboot) section_reboot ;;
        reboot-all) section_reboot_all ;;
        reboot-host) section_reboot_host ;;
        all)
            section_prereq
            section_schema
            section_hidden
            section_raw
            section_cleanup
            section_proxy
            section_stall
            section_ownership
            section_reboot_all
            ;;
        *)
            echo "Unknown section: $1" >&2
            exit 2
            ;;
    esac
}

run_section "$RUN_SECTION"

echo ""
echo -e "${BLUE}Summary:${NC} ${GREEN}$TESTS_PASSED passed${NC}, ${RED}$TESTS_FAILED failed${NC}, ${YELLOW}$TESTS_SKIPPED skipped${NC}"
if [[ -n "$SCENARIO_SUMMARY_LINES" ]]; then
    echo -e "${BLUE}Scenario metrics:${NC}"
    printf "%b" "$SCENARIO_SUMMARY_LINES"
fi

if [[ $TESTS_FAILED -gt 0 ]]; then
    exit 1
fi
exit 0
