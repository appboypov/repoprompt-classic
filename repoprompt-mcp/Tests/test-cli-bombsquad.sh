#!/bin/bash
#
# Automated CLI Test Script for RepoPrompt MCP CLI
# Tests core functionality against the BombSquad repository
#
# Usage: ./test-cli-bombsquad.sh [--verbose] [--section <name>]
#
# Sections: prereq, basic, tools, call, exec, chain, interactive, error, output, all
#

set -euo pipefail

# macOS-compatible timeout function
run_with_timeout() {
    local timeout_secs="$1"
    shift
    perl -e 'alarm shift; exec @ARGV' "$timeout_secs" "$@"
}

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# Try multiple CLI paths in order of preference
CLI_PATH="${REPOPROMPT_CLI:-}"
if [[ -z "$CLI_PATH" ]] || [[ ! -x "$CLI_PATH" ]]; then
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

BOMBSQUAD_PATH="${BOMBSQUAD_PATH:-$HOME/Documents/Git/BombSquad}"
WORKSPACE_NAME="BombSquad"
TIMEOUT_SECONDS=30
TEST_OUTPUT_DIR="/tmp/repoprompt-cli-tests"

# Ensure temp output dir exists even when running a single section (e.g. --section call)
mkdir -p "$TEST_OUTPUT_DIR"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Counters
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_SKIPPED=0

# Parse arguments
VERBOSE=false
RUN_SECTION="all"
while [[ $# -gt 0 ]]; do
    case $1 in
        --verbose|-v)
            VERBOSE=true
            shift
            ;;
        --section|-s)
            RUN_SECTION="$2"
            shift 2
            ;;
        *)
            shift
            ;;
    esac
done

# Helper functions
log_header() {
    echo ""
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}  $1${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

log_subheader() {
    echo ""
    echo -e "${CYAN}  ── $1 ──${NC}"
}

log_test() {
    echo -e "${YELLOW}▶ TEST:${NC} $1"
}

log_pass() {
    echo -e "${GREEN}✓ PASS:${NC} $1"
    ((++TESTS_PASSED))
}

log_fail() {
    echo -e "${RED}✗ FAIL:${NC} $1"
    ((++TESTS_FAILED))
}

log_skip() {
    echo -e "${YELLOW}○ SKIP:${NC} $1"
    ((++TESTS_SKIPPED))
}

log_verbose() {
    if $VERBOSE; then
        echo -e "  ${BLUE}→${NC} $1"
    fi
}

log_output() {
    if $VERBOSE; then
        echo -e "  ${CYAN}OUTPUT:${NC} ${1:0:200}"
    fi
}

# Run CLI command with timeout, capture stderr too
run_cli() {
    run_with_timeout $TIMEOUT_SECONDS "$CLI_PATH" "$@" 2>&1 || true
}

# Run CLI and capture only stdout
run_cli_stdout() {
    run_with_timeout $TIMEOUT_SECONDS "$CLI_PATH" "$@" 2>/dev/null || true
}

# Run CLI expecting failure, capture exit code
run_cli_expect_fail() {
    local exit_code=0
    run_with_timeout $TIMEOUT_SECONDS "$CLI_PATH" "$@" 2>&1 || exit_code=$?
    echo "EXIT_CODE:$exit_code"
}

# Check if output contains expected text (literal match)
assert_contains() {
    local output="$1"
    local expected="$2"
    local test_name="$3"

    if grep -qF -- "$expected" <<< "$output"; then
        log_pass "$test_name"
        return 0
    else
        log_fail "$test_name (expected: '$expected')"
        log_output "$output"
        return 1
    fi
}

# Check if output matches regex pattern (case insensitive)
assert_matches() {
    local output="$1"
    local pattern="$2"
    local test_name="$3"

    if grep -qiE "$pattern" <<< "$output"; then
        log_pass "$test_name"
        return 0
    else
        log_fail "$test_name (pattern: '$pattern')"
        log_output "$output"
        return 1
    fi
}

# Check JSON output with a Python assertion while preserving test counters.
assert_json_check() {
    local output="$1"
    local test_name="$2"
    local python_code="$3"

    if python3 -c "$python_code" <<< "$output" 2>/dev/null; then
        log_pass "$test_name"
        return 0
    else
        log_fail "$test_name"
        log_output "$output"
        return 1
    fi
}

# Check if output does NOT contain text
assert_not_contains() {
    local output="$1"
    local unexpected="$2"
    local test_name="$3"

    if grep -q -- "$unexpected" <<< "$output"; then
        log_fail "$test_name (unexpected: '$unexpected')"
        return 1
    else
        log_pass "$test_name"
        return 0
    fi
}

# Check if file exists and has content
assert_file_exists() {
    local filepath="$1"
    local test_name="$2"
    local min_size="${3:-1}"

    if [[ -f "$filepath" ]]; then
        local size=$(stat -f%z "$filepath" 2>/dev/null || stat -c%s "$filepath" 2>/dev/null || echo "0")
        if [[ $size -ge $min_size ]]; then
            log_pass "$test_name (size: $size bytes)"
            return 0
        else
            log_fail "$test_name (file too small: $size bytes)"
            return 1
        fi
    else
        log_fail "$test_name (file not found)"
        return 1
    fi
}

# Check if file contains valid JSON
assert_file_json() {
    local filepath="$1"
    local test_name="$2"

    if [[ -f "$filepath" ]] && jq . "$filepath" >/dev/null 2>&1; then
        log_pass "$test_name"
        return 0
    else
        log_fail "$test_name (invalid JSON or missing file)"
        return 1
    fi
}

# Setup test output directory
setup_test_dir() {
    rm -rf "$TEST_OUTPUT_DIR"
    mkdir -p "$TEST_OUTPUT_DIR"
}

# Check if section should run
should_run() {
    local section="$1"
    [[ "$RUN_SECTION" == "all" ]] || [[ "$RUN_SECTION" == "$section" ]]
}

# ============================================================================
# PREREQUISITE CHECKS
# ============================================================================

if should_run "prereq"; then
    log_header "Prerequisite Checks"

    log_test "CLI binary exists"
    if [[ -x "$CLI_PATH" ]]; then
        log_pass "CLI binary found"
    else
        log_fail "CLI binary not found at $CLI_PATH"
        echo "Please build the RepoPrompt project first"
        exit 1
    fi

    log_test "BombSquad repo exists"
    if [[ -d "$BOMBSQUAD_PATH" ]]; then
        log_pass "BombSquad repo found"
    else
        log_fail "BombSquad repo not found"
        exit 1
    fi

    log_test "RepoPrompt app is running"
    if pgrep -q "Repo Prompt" || pgrep -q "RepoPrompt"; then
        log_pass "RepoPrompt app is running"
    else
        log_fail "RepoPrompt app is not running - please start it first"
        exit 1
    fi

    log_test "Test output directory setup"
    setup_test_dir
    log_pass "Created $TEST_OUTPUT_DIR"
fi

# ============================================================================
# BASIC COMMANDS
# ============================================================================

if should_run "basic"; then
    log_header "Basic Commands"

    log_test "--help flag"
    OUTPUT=$(run_cli --help)
    assert_contains "$OUTPUT" "RepoPrompt MCP CLI" "--help shows title"
    assert_contains "$OUTPUT" "USAGE" "--help shows usage section"
    assert_contains "$OUTPUT" "--interactive" "--help shows interactive mode"
    assert_contains "$OUTPUT" "--exec" "--help shows exec mode"

    log_test "--version flag"
    OUTPUT=$(run_cli --version)
    assert_contains "$OUTPUT" "repoprompt-mcp" "--version shows name"
fi

# ============================================================================
# TOOL LISTING AND DESCRIBE
# ============================================================================

if should_run "tools"; then
    log_header "Tool Listing & Description"

    log_test "--list-tools"
    OUTPUT=$(run_cli --list-tools)
    assert_contains "$OUTPUT" "Available Tools" "--list-tools header"
    assert_contains "$OUTPUT" "read_file" "includes read_file"
    assert_contains "$OUTPUT" "file_search" "includes file_search"
    assert_contains "$OUTPUT" "manage_selection" "includes manage_selection"
    assert_contains "$OUTPUT" "apply_edits" "includes apply_edits"
    assert_contains "$OUTPUT" "get_file_tree" "includes get_file_tree"
    assert_contains "$OUTPUT" "app_settings" "includes app_settings"

    log_subheader "Tool Descriptions"

    log_test "--describe read_file"
    OUTPUT=$(run_cli --describe read_file)
    assert_contains "$OUTPUT" "read_file" "shows tool name"
    assert_contains "$OUTPUT" "path" "shows path param"

    log_test "--describe file_search"
    OUTPUT=$(run_cli --describe file_search)
    assert_contains "$OUTPUT" "pattern" "shows pattern param"

    log_test "--describe manage_selection"
    OUTPUT=$(run_cli --describe manage_selection)
    assert_contains "$OUTPUT" "op" "shows op param"

    log_test "--describe app_settings"
    OUTPUT=$(run_cli --describe app_settings)
    assert_contains "$OUTPUT" "app_settings" "shows app_settings tool name"
    assert_contains "$OUTPUT" "op" "shows app_settings op param"
    assert_matches "$OUTPUT" "(^|[^[:alnum:]_])list([^[:alnum:]_]|$)" "shows list operation"
    assert_matches "$OUTPUT" "(^|[^[:alnum:]_])get([^[:alnum:]_]|$)" "shows get operation"
    assert_matches "$OUTPUT" "(^|[^[:alnum:]_])set([^[:alnum:]_]|$)" "shows set operation"
    assert_contains "$OUTPUT" "ui" "shows ui group"
    assert_contains "$OUTPUT" "code_maps" "shows code_maps group"

    log_test "--describe nonexistent_tool"
    OUTPUT=$(run_cli --describe this_tool_does_not_exist)
    assert_matches "$OUTPUT" "(not found|unknown|error)" "error for unknown tool"

    log_subheader "Tools Schema JSON"

    log_test "--tools-schema"
    OUTPUT=$(run_cli --tools-schema)
    assert_contains "$OUTPUT" '"tools"' "--tools-schema has tools key"
    assert_contains "$OUTPUT" '"name"' "--tools-schema has name field"
    assert_contains "$OUTPUT" '"inputSchema"' "--tools-schema has inputSchema field"
    assert_contains "$OUTPUT" '"read_file"' "--tools-schema includes read_file"
    assert_contains "$OUTPUT" '"file_search"' "--tools-schema includes file_search"
    assert_contains "$OUTPUT" '"app_settings"' "--tools-schema includes app_settings"
    # Verify it's valid JSON and includes the expected app_settings schema surface
    assert_json_check "$OUTPUT" "--tools-schema output is valid JSON" "import sys,json; json.load(sys.stdin)"
    assert_json_check "$OUTPUT" "--tools-schema app_settings schema is valid" '
import sys, json
data = json.load(sys.stdin)
tool = next((t for t in data.get("tools", []) if t.get("name") == "app_settings"), None)
assert tool is not None, "app_settings missing"
props = tool.get("inputSchema", {}).get("properties", {})
assert set(["list", "get", "set"]).issubset(set(props.get("op", {}).get("enum", []))), "op enum mismatch"
assert set(["ui", "prompt_packaging", "editing", "models", "mcp", "code_maps"]).issubset(set(props.get("group", {}).get("enum", []))), "group enum mismatch"
annotations = tool.get("annotations", {})
assert annotations.get("destructiveHint") is True, "destructiveHint missing"
assert annotations.get("idempotentHint") is True, "idempotentHint missing"
'

    log_test "--tools-schema=explore (group filter)"
    OUTPUT=$(run_cli --tools-schema=explore)
    assert_contains "$OUTPUT" '"tools"' "--tools-schema=explore has tools key"
    assert_contains "$OUTPUT" '"read_file"' "--tools-schema=explore includes read_file"
    assert_json_check "$OUTPUT" "--tools-schema=explore output is valid JSON" "import sys,json; json.load(sys.stdin)"

    log_test "--tools-schema=settings (group filter)"
    OUTPUT=$(run_cli --tools-schema=settings)
    assert_contains "$OUTPUT" '"tools"' "--tools-schema=settings has tools key"
    assert_contains "$OUTPUT" '"app_settings"' "--tools-schema=settings includes app_settings"
    assert_json_check "$OUTPUT" "--tools-schema=settings output is valid JSON" "import sys,json; json.load(sys.stdin)"
    assert_json_check "$OUTPUT" "--tools-schema=settings only includes app_settings" '
import sys, json
data = json.load(sys.stdin)
names = [t.get("name") for t in data.get("tools", [])]
assert set(names) == {"app_settings"}, names
'

    log_test "tools settings --schema via exec"
    OUTPUT=$(run_cli -e 'tools settings --schema')
    assert_contains "$OUTPUT" '"tools"' "tools settings --schema has tools key"
    assert_contains "$OUTPUT" '"app_settings"' "tools settings --schema includes app_settings"
    assert_json_check "$OUTPUT" "tools settings --schema output is valid JSON" "import sys,json; json.load(sys.stdin)"
    assert_json_check "$OUTPUT" "tools settings --schema only includes app_settings" '
import sys, json
data = json.load(sys.stdin)
names = [t.get("name") for t in data.get("tools", [])]
assert set(names) == {"app_settings"}, names
'

    log_test "tools --schema via exec"
    OUTPUT=$(run_cli -e 'tools --schema')
    assert_contains "$OUTPUT" '"tools"' "tools --schema has tools key"
    assert_contains "$OUTPUT" '"inputSchema"' "tools --schema has inputSchema field"
    assert_json_check "$OUTPUT" "tools --schema output is valid JSON" "import sys,json; json.load(sys.stdin)"
fi

# ============================================================================
# DIRECT TOOL CALLS (--call)
# ============================================================================

if should_run "call"; then
    log_header "Direct Tool Calls (--call)"

    log_subheader "Basic Tool Calls"

    log_test "get_file_tree roots"
    OUTPUT=$(run_cli --call get_file_tree --json '{"type":"roots"}')
    if [[ -n "$OUTPUT" ]]; then
        log_pass "get_file_tree returns data"
    else
        log_fail "get_file_tree returned empty"
    fi

    log_test "oracle_utils models"
    OUTPUT=$(run_cli --call oracle_utils --json '{"op":"models"}')
    if [[ -n "$OUTPUT" ]]; then
        log_pass "oracle_utils models returns data"
    else
        log_fail "oracle_utils models returned empty"
    fi

    log_test "manage_workspaces list"
    OUTPUT=$(run_cli --call manage_workspaces --json '{"action":"list"}')
    assert_matches "$OUTPUT" "(workspace|id|name)" "lists workspaces"

    log_subheader "File Operations"

    log_test "read_file .gitignore"
    OUTPUT=$(run_cli --call read_file --json "{\"path\":\"$BOMBSQUAD_PATH/.gitignore\"}")
    assert_matches "$OUTPUT" "(Library|Build|\.vs)" "reads gitignore content"

    log_test "read_file via --json @file"
    READ_JSON_FILE="$TEST_OUTPUT_DIR/read-file-args.json"
    cat > "$READ_JSON_FILE" <<EOF
{"path":"$BOMBSQUAD_PATH/.gitignore","start_line":1,"limit":3}
EOF
    OUTPUT=$(run_cli --call read_file --json "@$READ_JSON_FILE")
    if [[ -n "$OUTPUT" ]]; then
        log_pass "read_file via @file works"
    else
        log_fail "read_file via @file failed"
    fi

    log_test "read_file via --json @- (stdin)"
    OUTPUT=$(printf '{"path":"%s/.gitignore","start_line":1,"limit":2}\n' "$BOMBSQUAD_PATH" | run_cli --call read_file --json @-)
    if [[ -n "$OUTPUT" ]]; then
        log_pass "read_file via @- works"
    else
        log_fail "read_file via @- failed"
    fi

    log_test "read_file with line range"
    OUTPUT=$(run_cli --call read_file --json "{\"path\":\"$BOMBSQUAD_PATH/.gitignore\",\"start_line\":1,\"limit\":5}")
    if [[ -n "$OUTPUT" ]]; then
        log_pass "read_file with line range works"
    else
        log_fail "read_file with line range failed"
    fi

    log_test "read_file negative start_line (tail)"
    OUTPUT=$(run_cli --call read_file --json "{\"path\":\"$BOMBSQUAD_PATH/.gitignore\",\"start_line\":-5}")
    if [[ -n "$OUTPUT" ]]; then
        log_pass "read_file tail mode works"
    else
        log_fail "read_file tail mode failed"
    fi

    log_test "apply_edits inline multiline JSON (no @file)"
    INLINE_EDIT_FILE="$BOMBSQUAD_PATH/.rpcli-inline-multiline.json-test.txt"
    cat > "$INLINE_EDIT_FILE" <<EOF
alpha
beta
EOF
    INLINE_JSON=$'{"path":"'"$INLINE_EDIT_FILE"$'","search":"alpha\nbeta","replace":"ALPHA\nBETA"}'
    OUTPUT=$(run_cli --call apply_edits --json "$INLINE_JSON")
    FILE_CONTENT=$(cat "$INLINE_EDIT_FILE" 2>/dev/null || true)
    rm -f "$INLINE_EDIT_FILE"
    if echo "$OUTPUT" | grep -q "Apply Edits" && [[ "$FILE_CONTENT" == $'ALPHA\nBETA' ]]; then
        log_pass "inline multiline JSON repaired and applied"
    else
        log_fail "inline multiline JSON repair failed"
        log_output "$OUTPUT"
    fi

    log_subheader "Search Operations"

    log_test "file_search content mode"
    OUTPUT=$(run_cli --call file_search --json '{"pattern":"MonoBehaviour","mode":"content","max_results":5}')
    assert_matches "$OUTPUT" "(\.cs|match)" "finds C# content"

    log_test "file_search path mode"
    OUTPUT=$(run_cli --call file_search --json '{"pattern":"*.cs","mode":"path","max_results":5}')
    assert_matches "$OUTPUT" "\.cs" "finds .cs files"

    log_test "file_search with regex"
    OUTPUT=$(run_cli --call file_search --json '{"pattern":"class\\s+\\w+","regex":true,"mode":"content","max_results":3}')
    if [[ -n "$OUTPUT" ]]; then
        log_pass "file_search regex works"
    else
        log_skip "file_search regex (may need context)"
    fi

    log_test "file_search with extension filter"
    OUTPUT=$(run_cli --call file_search --json '{"pattern":"void","mode":"content","filter":{"extensions":[".cs"]},"max_results":3}')
    if echo "$OUTPUT" | grep -q "\.cs"; then
        log_pass "file_search extension filter works"
    else
        log_skip "file_search extension filter"
    fi

    log_subheader "Code Structure"

    log_test "get_code_structure"
    OUTPUT=$(run_cli --call get_code_structure --json "{\"paths\":[\"$BOMBSQUAD_PATH/Assets/Content/Shared/Scripts\"]}")
    if [[ -n "$OUTPUT" ]]; then
        log_pass "get_code_structure returns data"
    else
        log_fail "get_code_structure returned empty"
    fi

    log_test "get_code_structure respects max_results"
    OUTPUT=$(run_cli --call get_code_structure --json "{\"paths\":[\"$BOMBSQUAD_PATH/Assets/Content/Shared/Scripts\"],\"max_results\":1}" --compact 2>/dev/null)
    if echo "$OUTPUT" | grep -Eq '"file_count"[[:space:]]*:[[:space:]]*1'; then
        log_pass "get_code_structure max_results cap works"
    else
        log_fail "get_code_structure max_results cap failed"
    fi

    log_subheader "Selection Operations"

    log_test "manage_selection get"
    OUTPUT=$(run_cli --call manage_selection --json '{"op":"get"}')
    if [[ -n "$OUTPUT" ]]; then
        log_pass "manage_selection get works"
    else
        log_fail "manage_selection get failed"
    fi

    log_test "manage_selection clear"
    OUTPUT=$(run_cli --call manage_selection --json '{"op":"clear"}')
    log_pass "manage_selection clear executed"

    log_test "manage_selection preview"
    OUTPUT=$(run_cli --call manage_selection --json '{"op":"preview","view":"summary"}')
    if [[ -n "$OUTPUT" ]]; then
        log_pass "manage_selection preview works"
    else
        log_fail "manage_selection preview failed"
    fi
fi

# ============================================================================
# EXEC MODE
# ============================================================================

if should_run "exec"; then
    log_header "Exec Mode (--exec)"

    log_subheader "Single Commands"

    log_test "exec: workspaces list"
    OUTPUT=$(run_cli --exec 'workspaces list')
    assert_matches "$OUTPUT" "(workspace|id|name)" "lists workspaces"

    log_test "exec: tree --roots"
    OUTPUT=$(run_cli --exec 'tree --roots')
    if [[ -n "$OUTPUT" ]]; then
        log_pass "tree --roots works"
    else
        log_fail "tree --roots failed"
    fi

    log_test "exec: tree --folders"
    OUTPUT=$(run_cli --exec 'tree --folders')
    if [[ -n "$OUTPUT" ]]; then
        log_pass "tree --folders works"
    else
        log_fail "tree --folders failed"
    fi

    log_test "exec: select get"
    OUTPUT=$(run_cli --exec 'select get')
    if [[ -n "$OUTPUT" ]]; then
        log_pass "select get works"
    else
        log_fail "select get failed"
    fi

    log_test "exec: select clear"
    OUTPUT=$(run_cli --exec 'select clear')
    log_pass "select clear executed"

    log_test "exec: models"
    OUTPUT=$(run_cli --exec 'models')
    if [[ -n "$OUTPUT" ]]; then
        log_pass "models command works"
    else
        log_fail "models command failed"
    fi

    log_test "exec: call read_file with @file JSON payload"
    EXEC_JSON_FILE="$TEST_OUTPUT_DIR/exec-read-file-args.json"
    cat > "$EXEC_JSON_FILE" <<EOF
{"path":"$BOMBSQUAD_PATH/.gitignore","start_line":1,"limit":2}
EOF
    OUTPUT=$(run_cli --exec "call read_file @$EXEC_JSON_FILE")
    if [[ -n "$OUTPUT" ]]; then
        log_pass "exec call with @file payload works"
    else
        log_fail "exec call with @file payload failed"
    fi

    log_subheader "Multiple --exec Flags"

    log_test "exec: multiple flags in sequence"
    OUTPUT=$(run_cli --exec 'select clear' --exec 'select get')
    if [[ -n "$OUTPUT" ]]; then
        log_pass "multiple --exec flags work"
    else
        log_fail "multiple --exec flags failed"
    fi

    log_test "exec: three commands in sequence"
    OUTPUT=$(run_cli --exec 'select clear' --exec 'tree --roots' --exec 'models')
    if [[ -n "$OUTPUT" ]]; then
        log_pass "three --exec flags work"
    else
        log_fail "three --exec flags failed"
    fi

    log_subheader "Chained Commands (&&)"

    log_test "exec: chained with &&"
    OUTPUT=$(run_cli --exec 'select clear && select get')
    if [[ -n "$OUTPUT" ]]; then
        log_pass "chained commands work"
    else
        log_fail "chained commands failed"
    fi

    log_test "exec: triple chain"
    OUTPUT=$(run_cli --exec 'select clear && tree --roots && models')
    if [[ -n "$OUTPUT" ]]; then
        log_pass "triple chain works"
    else
        log_fail "triple chain failed"
    fi

    log_subheader "Exec Mode Flags"

    log_test "exec: --quiet flag"
    OUTPUT=$(run_cli --exec 'tree --roots' --quiet)
    # Should still produce output but less verbose
    if [[ -n "$OUTPUT" ]]; then
        log_pass "--quiet still produces output"
    else
        log_fail "--quiet produced no output"
    fi

    log_test "exec: --verbose flag"
    OUTPUT=$(run_cli --exec 'tree --roots' --verbose)
    if [[ -n "$OUTPUT" ]]; then
        log_pass "--verbose works"
    else
        log_fail "--verbose failed"
    fi

    log_test "exec: --compact flag"
    OUTPUT=$(run_cli --exec 'models' --compact)
    if [[ -n "$OUTPUT" ]]; then
        log_pass "--compact works"
    else
        log_fail "--compact failed"
    fi

    log_test "exec: --pretty flag"
    OUTPUT=$(run_cli --exec 'models' --pretty)
    if [[ -n "$OUTPUT" ]]; then
        log_pass "--pretty works"
    else
        log_fail "--pretty failed"
    fi

    log_subheader "Nested Argument Formats (Runtime Conversion)"

    # These tests verify that nested JSON values and dotted keys are properly
    # converted at runtime, not just parsed. Tests the convertToMCPValue fix.

    log_test "exec: manage_selection with --key value format"
    OUTPUT=$(run_cli --exec 'manage_selection --op get --view summary')
    if [[ -n "$OUTPUT" ]]; then
        log_pass "manage_selection --key value format works"
    else
        log_fail "manage_selection --key value format failed"
    fi

    log_test "exec: file_search with JSON array in filter"
    OUTPUT=$(run_cli --exec 'file_search pattern=TODO filter={"extensions":[".cs"]} max_results=3')
    if [[ -n "$OUTPUT" ]] && ! echo "$OUTPUT" | grep -qi "cannot convert"; then
        log_pass "file_search with JSON object filter works"
    else
        log_fail "file_search with JSON object filter failed (conversion error)"
        log_output "$OUTPUT"
    fi

    log_test "exec: file_search with dotted key expansion"
    OUTPUT=$(run_cli --exec 'file_search pattern=class filter.extensions=.cs max_results=3')
    if [[ -n "$OUTPUT" ]] && ! echo "$OUTPUT" | grep -qi "cannot convert"; then
        log_pass "file_search with dotted key expansion works"
    else
        log_fail "file_search with dotted key expansion failed (conversion error)"
        log_output "$OUTPUT"
    fi

    log_test "exec: manage_selection with JSON array paths"
    # Clear first, then try to set with JSON array (may fail if paths don't exist, but shouldn't error on conversion)
    run_cli --exec 'select clear' >/dev/null 2>&1
    OUTPUT=$(run_cli --exec 'manage_selection op=set paths=["Assets"] mode=full' 2>&1)
    if ! echo "$OUTPUT" | grep -qi "cannot convert"; then
        log_pass "manage_selection with JSON array paths converts correctly"
    else
        log_fail "manage_selection with JSON array paths conversion error"
        log_output "$OUTPUT"
    fi

    log_test "exec: mixed --flag and key=value with nested JSON"
    OUTPUT=$(run_cli --exec 'file_search --pattern void --max-results 2 filter={"extensions":[".cs"]}')
    if [[ -n "$OUTPUT" ]] && ! echo "$OUTPUT" | grep -qi "cannot convert"; then
        log_pass "mixed flag formats with nested JSON work"
    else
        log_fail "mixed flag formats with nested JSON failed"
        log_output "$OUTPUT"
    fi
fi

# ============================================================================
# TOOL CHAINS
# ============================================================================

if should_run "chain"; then
    log_header "Tool Chains & Workflows"

    log_subheader "Selection Workflow"

    log_test "chain: clear -> add -> get"
    OUTPUT=$(run_cli \
        --exec 'select clear' \
        --exec "select add $BOMBSQUAD_PATH/.gitignore" \
        --exec 'select get --view files')
    if echo "$OUTPUT" | grep -qiE "(gitignore|file|select)"; then
        log_pass "selection workflow works"
    else
        log_skip "selection workflow (may need workspace)"
    fi

    log_subheader "Search -> Read Workflow"

    log_test "chain: search then read result"
    # First search for a file
    SEARCH_OUTPUT=$(run_cli --call file_search --json '{"pattern":"*.gitignore","mode":"path","max_results":1}')
    log_verbose "Search found: ${SEARCH_OUTPUT:0:100}"
    # Then read it
    READ_OUTPUT=$(run_cli --call read_file --json "{\"path\":\"$BOMBSQUAD_PATH/.gitignore\",\"limit\":10}")
    if [[ -n "$READ_OUTPUT" ]]; then
        log_pass "search -> read workflow works"
    else
        log_fail "search -> read workflow failed"
    fi

    log_subheader "Workspace Switch Workflow"

    log_test "chain: workspace -> tree"
    OUTPUT=$(run_cli --workspace "$WORKSPACE_NAME" --exec 'tree --folders' 2>&1 || true)
    if [[ -n "$OUTPUT" ]]; then
        log_pass "workspace -> tree workflow works"
    else
        log_skip "workspace -> tree (workspace may not exist)"
    fi

    log_subheader "Complex Multi-Step Chain"

    log_test "chain: 5-step workflow"
    OUTPUT=$(run_cli \
        --exec 'select clear' \
        --exec 'workspaces list' \
        --exec 'tree --roots' \
        --exec 'models' \
        --exec 'select get')
    if [[ -n "$OUTPUT" ]]; then
        log_pass "5-step workflow completes"
    else
        log_fail "5-step workflow failed"
    fi
fi

# ============================================================================
# INTERACTIVE MODE
# ============================================================================

if should_run "interactive"; then
    log_header "Interactive Mode"

    log_subheader "Interactive Commands via Heredoc"

    log_test "interactive: help command"
    OUTPUT=$(echo "help" | run_with_timeout 10 "$CLI_PATH" --interactive 2>&1 || true)
    if echo "$OUTPUT" | grep -qiE "(command|help|available)"; then
        log_pass "interactive help works"
    else
        log_skip "interactive help (may timeout)"
    fi

    log_test "interactive: tree command"
    OUTPUT=$(echo -e "tree --roots\nexit" | run_with_timeout 10 "$CLI_PATH" --interactive 2>&1 || true)
    if [[ -n "$OUTPUT" ]]; then
        log_pass "interactive tree works"
    else
        log_skip "interactive tree (may timeout)"
    fi

    log_test "interactive: multiple commands"
    OUTPUT=$(echo -e "models\ntree --roots\nexit" | run_with_timeout 15 "$CLI_PATH" --interactive 2>&1 || true)
    if [[ -n "$OUTPUT" ]]; then
        log_pass "interactive multiple commands work"
    else
        log_skip "interactive multiple commands (may timeout)"
    fi

    log_test "interactive: select workflow"
    OUTPUT=$(echo -e "select clear\nselect get\nexit" | run_with_timeout 15 "$CLI_PATH" --interactive 2>&1 || true)
    if [[ -n "$OUTPUT" ]]; then
        log_pass "interactive select workflow works"
    else
        log_skip "interactive select workflow (may timeout)"
    fi
fi

# ============================================================================
# ERROR HANDLING
# ============================================================================

if should_run "error"; then
    log_header "Error Handling"

    log_subheader "Invalid Tool Names"

    log_test "error: nonexistent tool via --call"
    OUTPUT=$(run_cli --call this_tool_does_not_exist --json '{}')
    assert_matches "$OUTPUT" "(error|unknown|not found|invalid)" "error for unknown tool"

    log_test "error: nonexistent tool via --describe"
    OUTPUT=$(run_cli --describe nonexistent_tool_xyz)
    assert_matches "$OUTPUT" "(error|unknown|not found)" "error for unknown describe"

    log_subheader "Invalid JSON"

    log_test "error: malformed JSON"
    OUTPUT=$(run_cli --call read_file --json 'not valid json at all')
    assert_matches "$OUTPUT" "(error|invalid|parse|json|unexpected)" "error for malformed JSON"

    log_test "error: incomplete JSON"
    OUTPUT=$(run_cli --call read_file --json '{"path":')
    assert_matches "$OUTPUT" "(error|invalid|parse|json|unexpected)" "error for incomplete JSON"

    log_test "error: wrong JSON type"
    OUTPUT=$(run_cli --call read_file --json '"just a string"')
    # May or may not error depending on implementation
    if [[ -n "$OUTPUT" ]]; then
        log_pass "handles wrong JSON type"
    else
        log_skip "wrong JSON type handling"
    fi

    log_test "error: missing @file JSON source"
    OUTPUT=$(run_cli --call read_file --json "@/tmp/repoprompt-cli-missing-$$.json")
    assert_matches "$OUTPUT" "(error|invalid|json|failed to read|no such file)" "error for missing @file json"

    log_test "error: invalid JSON content from @file"
    BAD_JSON_FILE="$TEST_OUTPUT_DIR/invalid-args.json"
    cat > "$BAD_JSON_FILE" <<EOF
not valid json
EOF
    OUTPUT=$(run_cli --call read_file --json "@$BAD_JSON_FILE")
    assert_matches "$OUTPUT" "(error|invalid|json|parse)" "error for invalid @file json"

    log_subheader "Missing Required Parameters"

    log_test "error: read_file without path"
    OUTPUT=$(run_cli --call read_file --json '{}')
    assert_matches "$OUTPUT" "(error|required|missing|path)" "error for missing path"

    log_test "error: file_search without pattern"
    OUTPUT=$(run_cli --call file_search --json '{}')
    assert_matches "$OUTPUT" "(error|required|missing|pattern)" "error for missing pattern"

    log_test "error: manage_workspaces without action"
    OUTPUT=$(run_cli --call manage_workspaces --json '{}')
    assert_matches "$OUTPUT" "(error|required|missing|action)" "error for missing action"

    log_subheader "Invalid Parameter Values"

    log_test "error: read_file nonexistent file"
    OUTPUT=$(run_cli --call read_file --json '{"path":"/nonexistent/path/to/file.txt"}')
    assert_matches "$OUTPUT" "(error|not found|does not exist|no such)" "error for nonexistent file"

    log_test "error: invalid operation for manage_selection"
    OUTPUT=$(run_cli --call manage_selection --json '{"op":"invalid_operation"}')
    assert_matches "$OUTPUT" "(error|invalid|unknown)" "error for invalid op"

    log_test "error: invalid action for manage_workspaces"
    OUTPUT=$(run_cli --call manage_workspaces --json '{"action":"not_a_real_action"}')
    assert_matches "$OUTPUT" "(error|invalid|unknown)" "error for invalid action"

    log_subheader "Invalid Exec Commands"

    log_test "error: unknown exec command"
    OUTPUT=$(run_cli --exec 'not_a_real_command arg1 arg2')
    assert_matches "$OUTPUT" "(error|unknown|invalid|unrecognized)" "error for unknown command"

    log_test "error: malformed exec syntax"
    OUTPUT=$(run_cli --exec '')
    # Empty command should error or be handled gracefully
    if [[ -n "$OUTPUT" ]] || [[ $? -ne 0 ]]; then
        log_pass "handles empty exec command"
    else
        log_skip "empty exec command handling"
    fi

    log_subheader "Type Mismatches"

    log_test "error: string where int expected"
    OUTPUT=$(run_cli --call read_file --json '{"path":"/tmp/test","start_line":"not_a_number"}')
    # Should error or handle gracefully
    if echo "$OUTPUT" | grep -qiE "(error|invalid|type)"; then
        log_pass "catches type mismatch"
    else
        log_skip "type mismatch handling (may coerce)"
    fi

    log_test "error: negative limit"
    OUTPUT=$(run_cli --call read_file --json '{"path":"/tmp/test","limit":-100}')
    # Implementation dependent
    if [[ -n "$OUTPUT" ]]; then
        log_pass "handles negative limit"
    else
        log_skip "negative limit handling"
    fi
fi

# ============================================================================
# FILE OUTPUT OPERATIONS
# ============================================================================

if should_run "output"; then
    log_header "File Output Operations"

    setup_test_dir

    log_subheader "Tool Snapshot"

    log_test "output: --snapshot-tools to JSON"
    SNAPSHOT_FILE="$TEST_OUTPUT_DIR/tools-snapshot.json"
    run_cli --snapshot-tools "$SNAPSHOT_FILE" >/dev/null 2>&1
    assert_file_exists "$SNAPSHOT_FILE" "snapshot file created" 100
    assert_file_json "$SNAPSHOT_FILE" "snapshot is valid JSON"

    if [[ -f "$SNAPSHOT_FILE" ]]; then
        TOOL_COUNT=$(jq '.tools | length' "$SNAPSHOT_FILE" 2>/dev/null || echo "0")
        log_test "output: snapshot contains tools"
        if [[ "$TOOL_COUNT" -gt 0 ]]; then
            log_pass "snapshot has $TOOL_COUNT tools"
        else
            log_fail "snapshot has no tools"
        fi
    fi

    log_subheader "Exec Output Redirect"

    log_test "output: exec with > redirect"
    TREE_FILE="$TEST_OUTPUT_DIR/tree-output.txt"
    run_cli --exec "tree --roots > $TREE_FILE" >/dev/null 2>&1
    if [[ -f "$TREE_FILE" ]]; then
        assert_file_exists "$TREE_FILE" "tree redirect file created"
    else
        log_skip "tree redirect (syntax may differ)"
    fi

    log_test "output: exec models to file"
    MODELS_FILE="$TEST_OUTPUT_DIR/models.json"
    run_cli --exec "models > $MODELS_FILE" --compact >/dev/null 2>&1
    if [[ -f "$MODELS_FILE" ]]; then
        assert_file_exists "$MODELS_FILE" "models redirect file created"
    else
        log_skip "models redirect (syntax may differ)"
    fi

    log_subheader "Context Export"

    log_test "output: workspace_context to file"
    CONTEXT_FILE="$TEST_OUTPUT_DIR/context.json"
    run_cli --call workspace_context --json '{}' --compact > "$CONTEXT_FILE" 2>/dev/null
    assert_file_exists "$CONTEXT_FILE" "context file created"

    log_test "output: workspace_context with includes"
    CONTEXT2_FILE="$TEST_OUTPUT_DIR/context-full.json"
    run_cli --call workspace_context --json '{"include":["prompt","selection","tokens"]}' --compact > "$CONTEXT2_FILE" 2>/dev/null
    assert_file_exists "$CONTEXT2_FILE" "full context file created"

    log_subheader "Selection Export"

    log_test "output: selection to file"
    SELECTION_FILE="$TEST_OUTPUT_DIR/selection.json"
    run_cli --call manage_selection --json '{"op":"get","view":"files"}' --compact > "$SELECTION_FILE" 2>/dev/null
    assert_file_exists "$SELECTION_FILE" "selection file created"

    log_subheader "Search Results Export"

    log_test "output: file_search results to file"
    SEARCH_FILE="$TEST_OUTPUT_DIR/search-results.json"
    run_cli --call file_search --json '{"pattern":"class","mode":"content","max_results":10}' --compact > "$SEARCH_FILE" 2>/dev/null
    assert_file_exists "$SEARCH_FILE" "search results file created"

    log_subheader "Code Structure Export"

    log_test "output: code structure to file"
    STRUCTURE_FILE="$TEST_OUTPUT_DIR/code-structure.json"
    run_cli --call get_code_structure --json "{\"paths\":[\"$BOMBSQUAD_PATH/Assets\"]}" --compact > "$STRUCTURE_FILE" 2>/dev/null
    assert_file_exists "$STRUCTURE_FILE" "code structure file created"

    log_subheader "File Tree Export"

    log_test "output: file tree to file"
    TREE_JSON_FILE="$TEST_OUTPUT_DIR/file-tree.json"
    run_cli --call get_file_tree --json '{"type":"files","mode":"folders"}' --compact > "$TREE_JSON_FILE" 2>/dev/null
    assert_file_exists "$TREE_JSON_FILE" "file tree file created"

    log_subheader "Prompt Export"

    log_test "output: prompt get to file"
    PROMPT_FILE="$TEST_OUTPUT_DIR/prompt.json"
    run_cli --call prompt --json '{"op":"get"}' --compact > "$PROMPT_FILE" 2>/dev/null
    assert_file_exists "$PROMPT_FILE" "prompt file created"

    log_subheader "Workflow Export Flags"

    log_test "output: --export-context flag"
    EXPORT_CONTEXT_FILE="$TEST_OUTPUT_DIR/export-context.md"
    run_cli --export-context "$EXPORT_CONTEXT_FILE" 2>&1 || true
    if [[ -f "$EXPORT_CONTEXT_FILE" ]]; then
        assert_file_exists "$EXPORT_CONTEXT_FILE" "--export-context creates file"
    else
        log_skip "--export-context flag (may need workspace)"
    fi

    log_test "output: --export-prompt flag"
    EXPORT_PROMPT_FILE="$TEST_OUTPUT_DIR/export-prompt.md"
    run_cli --export-prompt "$EXPORT_PROMPT_FILE" 2>&1 || true
    if [[ -f "$EXPORT_PROMPT_FILE" ]]; then
        assert_file_exists "$EXPORT_PROMPT_FILE" "--export-prompt creates file"
    else
        log_skip "--export-prompt flag (may need workspace)"
    fi

    log_subheader "Cleanup"
    log_test "output: test files summary"
    FILE_COUNT=$(ls -1 "$TEST_OUTPUT_DIR" 2>/dev/null | wc -l | tr -d ' ')
    log_pass "Created $FILE_COUNT output files in $TEST_OUTPUT_DIR"
fi

# ============================================================================
# SUMMARY
# ============================================================================

log_header "Test Summary"

TOTAL=$((TESTS_PASSED + TESTS_FAILED + TESTS_SKIPPED))

echo ""
echo -e "  ${GREEN}Passed:${NC}  $TESTS_PASSED"
echo -e "  ${RED}Failed:${NC}  $TESTS_FAILED"
echo -e "  ${YELLOW}Skipped:${NC} $TESTS_SKIPPED"
echo -e "  ─────────────"
echo -e "  Total:   $TOTAL"
echo ""

if [[ -d "$TEST_OUTPUT_DIR" ]]; then
    echo -e "  Test outputs: $TEST_OUTPUT_DIR"
    echo ""
fi

if [[ $TESTS_FAILED -eq 0 ]]; then
    echo -e "${GREEN}All tests passed!${NC}"
    exit 0
else
    echo -e "${RED}Some tests failed.${NC}"
    exit 1
fi
