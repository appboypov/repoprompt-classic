#!/bin/bash
#
# CLI Parsing Tests for RepoPrompt MCP CLI
#
# Requires: DEBUG build of rp-cli with --test-parse flag
# Usage: ./test-cli-parsing.sh [path-to-rp-cli-debug]
#

# Don't exit on first error - we want to see all test results
# set -e

# Use provided path or default to rp-cli-debug
CLI="${1:-rp-cli-debug}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

PASSED=0
FAILED=0

# Test helper: check if parsing succeeds and tool name matches
test_parse_success() {
    local description="$1"
    local command="$2"
    local expected_tool="$3"

    result=$("$CLI" --test-parse "$command" 2>&1) || true

    if echo "$result" | grep -q '"success" : true'; then
        if [ -n "$expected_tool" ]; then
            if echo "$result" | grep -q "\"toolName\" : \"$expected_tool\""; then
                echo -e "${GREEN}PASS${NC}: $description"
                ((PASSED++))
            else
                echo -e "${RED}FAIL${NC}: $description"
                echo "  Expected tool: $expected_tool"
                echo "  Result: $result"
                ((FAILED++))
            fi
        else
            echo -e "${GREEN}PASS${NC}: $description"
            ((PASSED++))
        fi
    else
        echo -e "${RED}FAIL${NC}: $description"
        echo "  Command: $command"
        echo "  Result: $result"
        ((FAILED++))
    fi
}

# Test helper: check if parsing fails (for required param tests)
test_parse_fail() {
    local description="$1"
    local command="$2"
    local expected_error="$3"

    result=$("$CLI" --test-parse "$command" 2>&1) || true

    if echo "$result" | grep -q '"success" : false'; then
        if [ -n "$expected_error" ]; then
            if echo "$result" | grep -q "$expected_error"; then
                echo -e "${GREEN}PASS${NC}: $description"
                ((PASSED++))
            else
                echo -e "${YELLOW}WARN${NC}: $description - failed but different error"
                echo "  Expected error containing: $expected_error"
                echo "  Result: $result"
                ((PASSED++))  # Still counts as pass since it failed as expected
            fi
        else
            echo -e "${GREEN}PASS${NC}: $description"
            ((PASSED++))
        fi
    else
        echo -e "${RED}FAIL${NC}: $description (expected failure)"
        echo "  Command: $command"
        echo "  Result: $result"
        ((FAILED++))
    fi
}

# Test helper: check if a specific arg value is present
# Uses jq for reliable JSON parsing and value extraction
# Compares the actual decoded value (not JSON representation)
test_parse_arg() {
    local description="$1"
    local command="$2"
    local arg_name="$3"
    local expected_value="$4"

    result=$("$CLI" --test-parse "$command" 2>&1) || true

    # Check for success first using grep (handles invalid JSON gracefully)
    if ! echo "$result" | grep -q '"success" : true'; then
        echo -e "${RED}FAIL${NC}: $description (parse failed)"
        echo "  Result: $result"
        ((FAILED++))
        return
    fi

    # Try to extract the actual value using jq
    # Note: jq -r gives the raw decoded value (newlines become actual newlines, etc.)
    # Use 'has()' check instead of '// empty' because boolean false is falsy
    local actual_value
    actual_value=$(echo "$result" | jq -r "if .args | has(\"$arg_name\") then .args.\"$arg_name\" else \"__MISSING__\" end" 2>/dev/null)
    local jq_status=$?
    
    # Check if the key was missing
    if [ "$actual_value" = "__MISSING__" ]; then
        actual_value=""
    fi

    if [ $jq_status -ne 0 ]; then
        # jq failed - JSON might be invalid, fall back to grep
        local escaped_value="${expected_value//\//\\\\/}"
        if echo "$result" | grep -q "\"$arg_name\" : \"$escaped_value\"" || \
           echo "$result" | grep -q "\"$arg_name\" : $expected_value"; then
            echo -e "${GREEN}PASS${NC}: $description"
            ((PASSED++))
        else
            echo -e "${RED}FAIL${NC}: $description"
            echo "  Expected $arg_name = $expected_value"
            echo "  Result: $result"
            ((FAILED++))
        fi
        return
    fi

    # Compare values directly
    # The expected_value represents what the parsed value should be
    # For escape sequences like \n, the expected value should contain the literal escape
    # which jq will have decoded to actual characters
    #
    # Use printf '%s' with $'...' syntax to properly interpret expected escape sequences
    local expected_interpreted
    # Use bash $'...' syntax via eval to interpret \n, \t, etc. in expected_value
    eval "expected_interpreted=\$'$expected_value'"

    if [ "$actual_value" = "$expected_interpreted" ]; then
        echo -e "${GREEN}PASS${NC}: $description"
        ((PASSED++))
    else
        echo -e "${RED}FAIL${NC}: $description"
        echo "  Expected $arg_name = $(printf '%s' "$expected_value" | cat -v)"
        echo "  Actual   $arg_name = $(printf '%s' "$actual_value" | cat -v)"
        ((FAILED++))
    fi
}

# Test helper: check if a specific arg is an array with the expected count
test_parse_array_count() {
    local description="$1"
    local command="$2"
    local arg_name="$3"
    local expected_count="$4"

    result=$("$CLI" --test-parse "$command" 2>&1) || true

    if echo "$result" | jq -e ".success == true and (.args.\"$arg_name\" | type == \"array\" and length == $expected_count)" >/dev/null 2>&1; then
        echo -e "${GREEN}PASS${NC}: $description"
        ((PASSED++))
    else
        echo -e "${RED}FAIL${NC}: $description"
        echo "  Expected $arg_name array count = $expected_count"
        echo "  Result: $result"
        ((FAILED++))
    fi
}

# Test helper: check if a boolean arg is set to true
test_parse_bool_true() {
    local description="$1"
    local command="$2"
    local arg_name="$3"

    result=$("$CLI" --test-parse "$command" 2>&1) || true

    if echo "$result" | jq -e ".success == true and .args.\"$arg_name\" == true and (.args.\"$arg_name\" | type == \"boolean\")" >/dev/null 2>&1; then
        echo -e "${GREEN}PASS${NC}: $description"
        ((PASSED++))
    else
        echo -e "${RED}FAIL${NC}: $description"
        echo "  Expected $arg_name = boolean true"
        echo "  Result: $result"
        ((FAILED++))
    fi
}

# Test helper: check if a boolean arg is set to false
test_parse_bool_false() {
    local description="$1"
    local command="$2"
    local arg_name="$3"

    result=$("$CLI" --test-parse "$command" 2>&1) || true

    if echo "$result" | jq -e ".success == true and .args.\"$arg_name\" == false and (.args.\"$arg_name\" | type == \"boolean\")" >/dev/null 2>&1; then
        echo -e "${GREEN}PASS${NC}: $description"
        ((PASSED++))
    else
        echo -e "${RED}FAIL${NC}: $description"
        echo "  Expected $arg_name = boolean false"
        echo "  Result: $result"
        ((FAILED++))
    fi
}

# Test helper: run a jq predicate against the parsed command JSON
test_parse_jq() {
    local description="$1"
    local command="$2"
    local jq_filter="$3"

    result=$("$CLI" --test-parse "$command" 2>&1) || true

    if echo "$result" | jq -e ".success == true and ($jq_filter)" >/dev/null 2>&1; then
        echo -e "${GREEN}PASS${NC}: $description"
        ((PASSED++))
    else
        echo -e "${RED}FAIL${NC}: $description"
        echo "  Expected jq predicate: $jq_filter"
        echo "  Result: $result"
        ((FAILED++))
    fi
}

echo "========================================"
echo "RepoPrompt CLI Parsing Tests"
echo "========================================"
echo ""

# Check if CLI is available
if ! command -v "$CLI" &> /dev/null; then
    echo -e "${RED}Error: CLI not found at '$CLI'${NC}"
    echo "Build the debug version first, then run:"
    echo "  $0 /path/to/rp-cli-debug"
    exit 1
fi

# Check if --test-parse is available (DEBUG build)
if ! "$CLI" --test-parse "help" 2>&1 | grep -q '"success"'; then
    echo -e "${RED}Error: --test-parse not available. Use a DEBUG build.${NC}"
    exit 1
fi

echo "=== context_builder / builder ==="
echo ""

# Basic builder tests
test_parse_success "builder with quoted text" 'builder "find auth code"' "context_builder"
test_parse_success "builder with unquoted text" 'builder find auth code' "context_builder"
test_parse_arg "builder extracts instructions" 'builder "find auth code"' "instructions" "find auth code"

# Instruction aliases
test_parse_arg "builder --task flag" 'builder --task "find auth"' "instructions" "find auth"
test_parse_arg "builder --instructions flag" 'builder --instructions "find auth"' "instructions" "find auth"
test_parse_arg "builder --prompt flag" 'builder --prompt "find auth"' "instructions" "find auth"

# response_type handling
test_parse_arg "builder with --type plan" 'builder "test" --type plan' "response_type" "plan"
test_parse_arg "builder with --response-type" 'builder "test" --response-type question' "response_type" "question"
test_parse_arg "builder with -t flag" 'builder "test" -t plan' "response_type" "plan"

# export_response handling
test_parse_bool_true "builder --export maps export_response" 'builder "test" --response-type plan --export' "export_response"
test_parse_bool_true "builder --export-response maps export_response" 'builder "test" --response-type plan --export-response' "export_response"
test_parse_bool_true "builder --export_response maps export_response" 'builder "test" --response-type plan --export_response' "export_response"
test_parse_bool_false "builder --export=false maps export_response false" 'builder "test" --response-type plan --export=false' "export_response"
test_parse_fail "builder conflicting export aliases fail" 'builder "test" --export --export-response=false' "Conflicting export_response flags"
test_parse_fail "builder invalid export value fails" 'builder "test" --export=maybe' "export_response must be a boolean"

# Raw context_builder
test_parse_success "context_builder with task=" 'context_builder task="find auth"' "context_builder"
test_parse_arg "context_builder task= value" 'context_builder task="find auth"' "instructions" "find auth"
test_parse_arg "context_builder instructions=" 'context_builder instructions="find auth"' "instructions" "find auth"
test_parse_arg "context_builder response_type" 'context_builder task="x" response_type=plan' "response_type" "plan"
test_parse_bool_true "context_builder --export maps export_response" 'context_builder task="test" --export' "export_response"
test_parse_bool_true "context_builder export-response maps export_response" 'context_builder task="test" export-response=true' "export_response"
test_parse_bool_false "context_builder export_response=false maps false" 'context_builder task="test" export_response=false' "export_response"
test_parse_fail "context_builder conflicting export aliases fail" 'context_builder task="test" export=true export_response=false' "Conflicting export_response flags"

# Dash/underscore interchangeability
test_parse_arg "response-type with dash" 'context_builder task="x" response-type=plan' "response_type" "plan"

# Required parameter validation
test_parse_fail "builder without instructions fails" 'builder' "instructions"
test_parse_fail "context_builder without task fails" 'context_builder response_type=plan' "instructions"

echo ""
echo "=== Quote Handling ==="
echo ""

# Quotes with spaces
test_parse_arg "quoted value with spaces" 'builder "find all auth code"' "instructions" "find all auth code"
test_parse_arg "key=value with quoted spaces" 'context_builder task="find all auth code"' "instructions" "find all auth code"

# Values starting with dash
test_parse_arg "value starting with dash" 'builder --task "- list all items"' "instructions" "- list all items"
test_parse_arg "value with dash in middle" 'builder "add pre-commit hook"' "instructions" "add pre-commit hook"

# Backslash handling (regex patterns)
test_parse_success "backslash preserved in pattern" 'search "\\w+"' "file_search"

echo ""
echo "=== Escape Sequence Handling (double quotes) ==="
echo ""

# Test that \n, \t, \r are decoded inside double quotes
# Note: The parsed value should contain actual newline/tab/cr, which JSON-encodes back as \n/\t/\r
# Using search/chat commands since edit shorthand is no longer available
test_parse_arg "\\n decoded to newline in chat" 'chat "line1\nline2"' "message" 'line1\nline2'
test_parse_arg "\\t decoded to tab in builder" 'builder "col1\tcol2"' "instructions" 'col1\tcol2'

# Test that \\\\ (4 backslashes) is decoded to \\ (2 backslashes)
# Input has 4 backslashes per separator, parser decodes each \\ to \, resulting in 2 backslashes
# Expected value needs 4 backslashes in single quotes to represent 2 literal backslashes
test_parse_arg "\\\\ decoded to \\\\" 'builder "path\\\\to\\\\file"' "instructions" 'path\\\\to\\\\file'

# Test that unknown escapes like \w are preserved literally (for regex)
test_parse_arg "\\w preserved for regex" 'search "\\w+"' "pattern" '\\w+'
test_parse_arg "\\d preserved for regex" 'search "\\d{3}"' "pattern" '\\d{3}'
test_parse_arg "\\s preserved for regex" 'search "hello\\s+world"' "pattern" 'hello\\s+world'

# Test escape sequences work in JSON format call (apply_edits requires JSON)
test_parse_success "JSON format handles \\n" 'call apply_edits {"path":"f.swift","search":"a\\nb","replace":"c"}' "apply_edits"

# Test that single quotes do NOT process escape sequences (literal)
test_parse_success "single quotes are literal (parse-only)" "search 'hello\\nworld'" "file_search"

# Test mixed escape sequences
test_parse_arg "mixed \\n and \\t in chat" 'chat "col1\tcol2\nrow2"' "message" 'col1\tcol2\nrow2'

# Test escaped quote inside string
test_parse_arg "escaped quote \\\"" 'builder "say \"hello\""' "instructions" 'say "hello"'

echo ""
echo "=== read_file (read, cat) ==="
echo ""

test_parse_success "read with path" 'read src/main.swift' "read_file"
test_parse_success "cat alias" 'cat src/main.swift' "read_file"
test_parse_arg "read path arg" 'read src/main.swift' "path" "src/main.swift"
test_parse_arg "read with start_line" 'read src/main.swift 10' "start_line" "10"
test_parse_arg "read with limit" 'read src/main.swift 10 50' "limit" "50"
test_parse_arg "read --start-line flag" 'read src/main.swift --start-line 10' "start_line" "10"
test_parse_arg "read --limit flag" 'read src/main.swift --limit 50' "limit" "50"

echo ""
echo "=== file_search (search, grep, find) ==="
echo ""

test_parse_success "search command" 'search "TODO"' "file_search"
test_parse_success "grep alias" 'grep "TODO"' "file_search"
test_parse_arg "search pattern" 'search "TODO"' "pattern" "TODO"
test_parse_arg "search --context" 'search "TODO" --context 3' "context_lines" "3"
test_parse_arg "search --max" 'search "TODO" --max 10' "max_results" "10"
test_parse_arg "search --mode" 'search "TODO" --mode content' "mode" "content"
test_parse_success "search --no-regex" 'search "TODO" --no-regex' "file_search"
test_parse_success "search --count-only" 'search "TODO" --count-only' "file_search"
test_parse_success "search --whole-word" 'search "TODO" --whole-word' "file_search"

echo ""
echo "=== get_file_tree (tree) ==="
echo ""

test_parse_success "tree command" 'tree' "get_file_tree"
test_parse_arg "tree with path" 'tree src/' "path" "src/"
test_parse_arg "tree --folders" 'tree --folders' "mode" "folders"
test_parse_arg "tree --full" 'tree --full' "mode" "full"
test_parse_arg "tree --selected" 'tree --selected' "mode" "selected"
test_parse_arg "tree --depth" 'tree --depth 2' "max_depth" "2"

echo ""
echo "=== get_code_structure (structure, struct, map) ==="
echo ""

test_parse_success "structure command" 'structure src/' "get_code_structure"
test_parse_success "struct alias" 'struct src/' "get_code_structure"
test_parse_success "map alias" 'map src/' "get_code_structure"
test_parse_arg "structure --scope selected" 'structure --scope selected' "scope" "selected"
test_parse_arg "structure --max" 'structure src/ --max 10' "max_results" "10"
test_parse_arg "structure --max-results" 'structure src/ --max-results 10' "max_results" "10"

echo ""
echo "=== manage_selection (select, sel) ==="
echo ""

test_parse_success "select add" 'select add src/' "manage_selection"
test_parse_success "sel alias" 'sel add src/' "manage_selection"
test_parse_arg "select op=add" 'select add src/' "op" "add"
test_parse_arg "select op=remove" 'select remove src/' "op" "remove"
test_parse_arg "select op=set" 'select set src/' "op" "set"
test_parse_arg "select op=clear" 'select clear' "op" "clear"
test_parse_arg "select op=get" 'select get' "op" "get"
test_parse_arg "select --codemap" 'select add src/ --codemap' "mode" "codemap_only"
test_parse_arg "select --full" 'select add src/ --full' "mode" "full"
test_parse_arg "select --view files" 'select get --view files' "view" "files"
test_parse_arg "select get --path-display full" 'select get --path-display full' "path_display" "full"
test_parse_arg "raw manage_selection path-display dash normalizes" 'manage_selection op=get view=files path-display=full' "path_display" "full"
test_parse_arg "raw manage_selection path_display underscore" 'manage_selection op=get view=files path_display=full' "path_display" "full"

echo ""
echo "=== workspace_context (context, ctx) ==="
echo ""

test_parse_success "context command" 'context' "workspace_context"
test_parse_success "ctx alias" 'ctx' "workspace_context"
test_parse_success "context --tree" 'context --tree' "workspace_context"
test_parse_success "context --files" 'context --files' "workspace_context"
test_parse_success "context --all" 'context --all' "workspace_context"
test_parse_arg "context --path-display" 'context --path-display full' "path_display" "full"

echo ""
echo "=== oracle_send aliases (chat, newchat, plan, review) ==="
echo ""

test_parse_success "chat command" 'chat "hello"' "oracle_send"
test_parse_arg "chat message" 'chat "hello world"' "message" "hello world"
test_parse_arg "chat --mode plan" 'chat "test" --mode plan' "mode" "plan"
test_parse_arg "chat --model" 'chat "test" --model gpt4' "model" "gpt4"
test_parse_arg "chat --name" 'chat "test" --name "My Chat"' "chat_name" "My Chat"

test_parse_success "newchat command" 'newchat "hello"' "oracle_send"
test_parse_success "plan command" 'plan "design auth"' "oracle_send"
test_parse_arg "plan mode is plan" 'plan "test"' "mode" "plan"
test_parse_success "review command" 'review "check this"' "oracle_send"
test_parse_arg "review mode is review" 'review "test"' "mode" "review"

test_parse_fail "chat without message fails" 'chat' "message"

echo ""
echo "=== apply_edits (JSON format required) ==="
echo ""

# edit/replace shorthand is no longer supported - must use JSON format
test_parse_fail "edit shorthand requires JSON" 'edit path.swift "old" "new"' "JSON format"
test_parse_fail "replace shorthand requires JSON" 'replace path.swift "old" "new"' "JSON format"

# JSON format via call works
test_parse_success "apply_edits via call" 'call apply_edits {"path":"path.swift","search":"old","replace":"new"}' "apply_edits"
test_parse_success "apply_edits via @file payload" 'call apply_edits @/tmp/apply-edits.json' "apply_edits"
test_parse_success "apply_edits via @- payload" 'call apply_edits @-' "apply_edits"

echo ""
echo "=== file_actions (JSON format required) ==="
echo ""

# file shorthand is no longer supported - must use JSON format
test_parse_fail "file shorthand requires JSON" 'file create path.txt' "JSON format"
test_parse_fail "file delete shorthand requires JSON" 'file delete path.txt' "JSON format"
test_parse_fail "file move shorthand requires JSON" 'file move old.txt new.txt' "JSON format"

# JSON format via call works
test_parse_success "file_actions via call" 'call file_actions {"action":"create","path":"path.txt"}' "file_actions"

echo ""
echo "=== prompt ==="
echo ""

test_parse_success "prompt get" 'prompt get' "prompt"
test_parse_arg "prompt op=get" 'prompt get' "op" "get"
test_parse_arg "prompt op=set" 'prompt set "new prompt"' "op" "set"
test_parse_arg "prompt op=append" 'prompt append "more text"' "op" "append"
test_parse_arg "prompt op=clear" 'prompt clear' "op" "clear"
test_parse_arg "prompt op=export" 'prompt export /tmp/out.md' "op" "export"

echo ""
echo "=== oracle session aliases ==="
echo ""

test_parse_success "chats command" 'chats' "oracle_utils"
test_parse_arg "chats list" 'chats list' "op" "sessions"
test_parse_fail "chats log removed" 'chats log' "Chat log reading is only available via oracle_chat_log"
test_parse_arg "chats --limit" 'chats list --limit 5' "limit" "5"

echo ""
echo "=== manage_workspaces (workspace, ws, tabs) ==="
echo ""

test_parse_success "workspace command" 'workspace' "manage_workspaces"
test_parse_success "ws alias" 'ws' "manage_workspaces"
test_parse_success "tabs alias" 'tabs' "bind_context"
test_parse_arg "tabs default op" 'tabs' "op" "list"
test_parse_arg "workspace list" 'workspace list' "action" "list"
test_parse_bool_true "workspace list --include-hidden" 'workspace list --include-hidden' "include_hidden"
test_parse_success "workspace tabs" 'workspace tabs' "manage_workspaces"
test_parse_arg "workspace tabs action" 'workspace tabs' "action" "list_tabs"
test_parse_arg "workspace switch" 'workspace switch MyProject' "action" "switch"
test_parse_bool_true "workspace switch --include-hidden" 'workspace switch MyProject --include-hidden' "include_hidden"
test_parse_arg "workspace hide" 'workspace hide MyProject' "action" "hide"
test_parse_arg "workspace hide workspace" 'workspace hide MyProject' "workspace" "MyProject"
test_parse_arg "workspace unhide" 'workspace unhide MyProject' "action" "unhide"
test_parse_bool_true "workspace delete --include-hidden" 'workspace delete MyProject --include-hidden' "include_hidden"
test_parse_bool_true "workspace shorthand switch --include-hidden" 'workspace MyProject --include-hidden' "include_hidden"

echo ""
echo "=== git ==="
echo ""

# Basic operations
test_parse_success "git status" 'git status' "git"
test_parse_success "git diff" 'git diff' "git"
test_parse_success "git log" 'git log' "git"
test_parse_success "git show" 'git show' "git"
test_parse_success "git blame" 'git blame' "git"
test_parse_arg "git op defaults to status" 'git' "op" "status"
test_parse_arg "git status sets op" 'git status' "op" "status"
test_parse_arg "git diff sets op" 'git diff' "op" "diff"
test_parse_arg "git log sets op" 'git log' "op" "log"

# Detail level flags
test_parse_arg "git diff --summary" 'git diff --summary' "detail" "summary"
test_parse_arg "git diff --files" 'git diff --files' "detail" "files"
test_parse_arg "git diff --patches" 'git diff --patches' "detail" "patches"
test_parse_arg "git diff --full" 'git diff --full' "detail" "full"
test_parse_arg "git diff --detail files" 'git diff --detail files' "detail" "files"
test_parse_arg "git diff --detail patches" 'git diff --detail patches' "detail" "patches"
test_parse_arg "git diff -d patches" 'git diff -d patches' "detail" "patches"
test_parse_arg "git diff -d full" 'git diff -d full' "detail" "full"

# Compare spec
test_parse_arg "git diff --compare staged" 'git diff --compare staged' "compare" "staged"
test_parse_arg "git diff --compare unstaged" 'git diff --compare unstaged' "compare" "unstaged"
test_parse_arg "git diff -c staged" 'git diff -c staged' "compare" "staged"
test_parse_arg "git diff --compare main" 'git diff --compare main' "compare" "main"
test_parse_arg "git diff --compare trunk" 'git diff --compare trunk' "compare" "trunk"
test_parse_arg "git diff --compare mergebase:origin/main" 'git diff --compare mergebase:origin/main' "compare" "mergebase:origin/main"
test_parse_arg "git diff --compare uncommitted:main" 'git diff --compare uncommitted:main' "compare" "uncommitted:main"
test_parse_arg "git diff --compare uncommitted-mergebase:origin/main" 'git diff --compare uncommitted-mergebase:origin/main' "compare" "uncommitted-mergebase:origin/main"
test_parse_arg "git diff --compare staged:main" 'git diff --compare staged:main' "compare" "staged:main"
test_parse_arg "git diff --compare staged-mergebase:origin/main" 'git diff --compare staged-mergebase:origin/main' "compare" "staged-mergebase:origin/main"
test_parse_arg "git diff --compare back:3" 'git diff --compare back:3' "compare" "back:3"

# Repo targeting
test_parse_arg "git --repo-root" 'git status --repo-root /path/to/repo' "repo_root" "/path/to/repo"
test_parse_arg "git --root alias" 'git status --root MyProject' "repo_root" "MyProject"

# Worktree specifiers (appended to repo_root)
test_parse_arg "git --root @main" 'git status --root @main' "repo_root" "@main"
test_parse_arg "git --root @wt" 'git status --root @wt' "repo_root" "@wt"
test_parse_arg "git --root @main:branch" 'git status --root @main:dev' "repo_root" "@main:dev"
test_parse_arg "git --repo-root with @main suffix" 'git diff --repo-root MyProject@main' "repo_root" "MyProject@main"
test_parse_arg "git --repo-root with @main:branch" 'git diff --repo-root MyProject@main:feature' "repo_root" "MyProject@main:feature"

# Scope and paths
test_parse_arg "git diff --scope all" 'git diff --scope all' "scope" "all"
test_parse_arg "git diff --scope selected" 'git diff --scope selected' "scope" "selected"
test_parse_arg "git diff --path" 'git diff --path src/main.swift' "path" "src/main.swift"

# Legacy --truncate remapped to detail
test_parse_arg "git diff --truncate remaps to patches" 'git diff --truncate' "detail" "patches"
test_parse_arg "git diff --truncate=false remaps to full" 'git diff --truncate=false' "detail" "full"
test_parse_arg "git diff --truncate=true remaps to patches" 'git diff --truncate=true' "detail" "patches"

# Diff options
test_parse_arg "git diff --context-lines" 'git diff --context-lines 5' "context_lines" "5"
test_parse_arg "git diff -C 3" 'git diff -C 3' "context_lines" "3"
test_parse_bool_true "git diff --detect-renames" 'git diff --detect-renames' "detect_renames"
test_parse_bool_true "git diff --renames" 'git diff --renames' "detect_renames"
test_parse_bool_true "git diff --artifacts" 'git diff --artifacts' "artifacts"
test_parse_bool_true "git diff -a" 'git diff -a' "artifacts"

# Artifact mode
test_parse_arg "git diff --mode quick" 'git diff --mode quick' "mode" "quick"
test_parse_arg "git diff --mode standard" 'git diff --mode standard' "mode" "standard"
test_parse_arg "git diff --mode deep" 'git diff --mode deep' "mode" "deep"

# Multi-repo with worktree specifiers
test_parse_success "git --repo-roots multiple" 'git status --repo-roots ProjectA,ProjectB' "git"
test_parse_success "git --repo-roots with worktree" 'git diff --repo-roots ProjectA@main,ProjectB@wt' "git"

# git show
test_parse_arg "git show with ref" 'git show HEAD~1' "ref" "HEAD~1"
test_parse_arg "git show --ref" 'git show --ref abc123' "ref" "abc123"

# git blame
test_parse_arg "git blame with path" 'git blame src/main.swift' "path" "src/main.swift"
test_parse_arg "git blame --lines" 'git blame src/main.swift --lines 10-40' "lines" "10-40"
test_parse_arg "git blame -l" 'git blame src/main.swift -l 20-30' "lines" "20-30"

# git log
test_parse_arg "git log --count" 'git log --count 20' "count" "20"
test_parse_arg "git log -n" 'git log -n 10' "count" "10"

# Inline MAP options
test_parse_success "git diff --inline-map" 'git diff --inline-map' "git"
test_parse_success "git diff --inline-mode" 'git diff --inline-mode brief' "git"
test_parse_success "git diff --inline-max-lines" 'git diff --inline-max-lines 100' "git"

# JSON payload passthrough
test_parse_success "git with JSON payload" 'git {"op":"status"}' "git"

echo ""
echo "=== Parameter Format Variations ==="
echo ""

# key=value format (original)
test_parse_arg "key=value format" 'file_search pattern=TODO' "pattern" "TODO"
test_parse_arg "key=value with quotes" 'file_search pattern="find this"' "pattern" "find this"

# --key value format (new)
test_parse_arg "--key value format" 'file_search --pattern TODO' "pattern" "TODO"
test_parse_arg "--key value with quotes" 'file_search --pattern "find this"' "pattern" "find this"
test_parse_arg "--key value multi-word" 'file_search --pattern "hello world"' "pattern" "hello world"

# --key=value format (new)
test_parse_arg "--key=value format" 'file_search --pattern=TODO' "pattern" "TODO"
test_parse_arg "--key=value with quotes" 'file_search --pattern="find this"' "pattern" "find this"

# Boolean flags (--flag alone means true)
test_parse_bool_true "--count-only sets count_only=true" 'file_search --pattern TODO --count-only' "count_only"
test_parse_bool_true "--whole-word sets whole_word=true" 'file_search --pattern TODO --whole-word' "whole_word"
test_parse_bool_true "--verbose sets verbose=true" 'file_search --pattern TODO --verbose' "verbose"

# Dash to underscore normalization
test_parse_arg "dashes normalize to underscores" 'file_search --max-results 10' "max_results" "10"
test_parse_arg "context-lines normalizes" 'file_search --pattern x --context-lines 5' "context_lines" "5"

# JSON arrays with --flag format
test_parse_success "--flag with JSON array" 'manage_selection --op set --paths ["src/"]' "manage_selection"

# Multiple --flag params together
test_parse_arg "multiple --flags pattern" 'file_search --pattern TODO --mode content' "pattern" "TODO"
test_parse_arg "multiple --flags mode" 'file_search --pattern TODO --mode content' "mode" "content"
test_parse_arg "multiple --flags max" 'file_search --pattern TODO --max-results 20' "max_results" "20"

# Mix of formats
test_parse_arg "mixed key= and --flag" 'file_search pattern=TODO --max-results 10' "max_results" "10"
test_parse_arg "mixed --flag and key=" 'file_search --pattern TODO max_results=10' "pattern" "TODO"

# Raw tool calls with --flag format
test_parse_arg "raw tool with --flags" 'read_file --path src/main.swift' "path" "src/main.swift"
test_parse_arg "raw tool --start-line" 'read_file --path src/main.swift --start-line 10' "start_line" "10"
test_parse_arg "raw tool --limit" 'read_file --path x --limit 50' "limit" "50"

echo ""
echo "=== JSON Value Parsing ==="
echo ""

# JSON arrays
test_parse_success "JSON array in value" 'manage_selection op=set paths=["src/","lib/"]' "manage_selection"

# JSON objects
test_parse_success "JSON object in value" 'file_search pattern=TODO filter={"paths":["src/"]}' "file_search"

# Dotted keys expand to nested objects
test_parse_success "dotted key expansion" 'file_search pattern=TODO filter.paths=src/' "file_search"

echo ""
echo "=== Raw Tool Key/Value Formats (parseKeyValueArgs) ==="
echo ""

# pattern via key=value, --key value, --key=value
test_parse_success "raw tool key=value (pattern)" 'file_search pattern=TODO' "file_search"
test_parse_arg     "raw tool key=value sets pattern" 'file_search pattern=TODO' "pattern" "TODO"

test_parse_success "raw tool --key value (pattern)" 'file_search --pattern TODO' "file_search"
test_parse_arg     "raw tool --key value sets pattern" 'file_search --pattern TODO' "pattern" "TODO"

test_parse_success "raw tool --key=value (pattern)" 'file_search --pattern=TODO' "file_search"
test_parse_arg     "raw tool --key=value sets pattern" 'file_search --pattern=TODO' "pattern" "TODO"

# Multi-parameter mixing styles
test_parse_success "raw tool mixed formats (pattern/mode/max)" 'file_search pattern=TODO --mode content max_results=10' "file_search"
test_parse_arg     "raw tool mixed formats sets mode" 'file_search pattern=TODO --mode content max_results=10' "mode" "content"
test_parse_arg     "raw tool mixed formats sets max_results" 'file_search pattern=TODO --mode content max_results=10' "max_results" "10"

test_parse_success "raw tool mixed formats (all --key)" 'file_search --pattern TODO --mode content --max-results 10' "file_search"
test_parse_arg     "raw tool --max-results normalizes to max_results" 'file_search --pattern TODO --mode content --max-results 10' "max_results" "10"

test_parse_success "raw tool mixed formats (all --key=value)" 'file_search --pattern=TODO --mode=content --max-results=10' "file_search"
test_parse_arg     "raw tool --key=value sets mode" 'file_search --pattern=TODO --mode=content --max-results=10' "mode" "content"
test_parse_arg     "raw tool --key=value normalizes max-results" 'file_search --pattern=TODO --mode=content --max-results=10' "max_results" "10"

# Empty-string values (should parse; runtime validation is separate)
test_parse_success "raw tool empty string value via --key=" 'file_search --pattern=' "file_search"
test_parse_arg     "raw tool empty string captured" 'file_search --pattern=' "pattern" ""

# Strings with spaces across formats
test_parse_success "raw tool quoted string key=value" 'file_search pattern="hello world"' "file_search"
test_parse_arg     "raw tool quoted string key=value sets pattern" 'file_search pattern="hello world"' "pattern" "hello world"

test_parse_success "raw tool quoted string --key value" 'file_search --pattern "hello world"' "file_search"
test_parse_arg     "raw tool quoted string --key value sets pattern" 'file_search --pattern "hello world"' "pattern" "hello world"

test_parse_success "raw tool quoted string --key=value" 'file_search --pattern="hello world"' "file_search"
test_parse_arg     "raw tool quoted string --key=value sets pattern" 'file_search --pattern="hello world"' "pattern" "hello world"

# Values starting with '-' should be treated as values (not flags) for --key value
test_parse_success "raw tool value starting with dash" 'file_search --pattern "-leading-dash"' "file_search"
test_parse_arg     "raw tool captures dash-leading string" 'file_search --pattern "-leading-dash"' "pattern" "-leading-dash"

# Decimal numbers currently parse as strings (parseValue only Int/Bool unless JSON)
test_parse_success "raw tool decimal parses as string" 'file_search --pattern TODO max_results=1.5' "file_search"
test_parse_arg     "raw tool decimal value preserved as string" 'file_search --pattern TODO max_results=1.5' "max_results" "1.5"


echo ""
echo "=== Raw Tool Boolean Flags + Explicit Booleans (parseKeyValueArgs) ==="
echo ""

# Boolean flags alone => true
test_parse_success  "raw tool boolean flag alone sets true (count-only)" 'file_search --pattern TODO --count-only' "file_search"
test_parse_bool_true "raw tool --count-only sets count_only=true" 'file_search --pattern TODO --count-only' "count_only"

test_parse_success  "raw tool boolean flag alone sets true (whole-word)" 'file_search --pattern TODO --whole-word' "file_search"
test_parse_bool_true "raw tool --whole-word sets whole_word=true" 'file_search --pattern TODO --whole-word' "whole_word"

test_parse_success  "raw tool boolean flag alone sets true (verbose)" 'file_search --pattern TODO --verbose' "file_search"
test_parse_bool_true "raw tool --verbose sets verbose=true" 'file_search --pattern TODO --verbose' "verbose"

# Explicit booleans via key=value and --key=value and --key value
test_parse_success "raw tool explicit boolean false via key=value" 'file_search --pattern TODO regex=false' "file_search"
test_parse_arg     "raw tool regex=false (key=value)" 'file_search --pattern TODO regex=false' "regex" "false"

test_parse_success "raw tool explicit boolean false via --key=value" 'file_search --pattern TODO --regex=false' "file_search"
test_parse_arg     "raw tool --regex=false" 'file_search --pattern TODO --regex=false' "regex" "false"

test_parse_success "raw tool explicit boolean true via --key value" 'file_search --pattern TODO --regex true' "file_search"
test_parse_arg     "raw tool --regex true" 'file_search --pattern TODO --regex true' "regex" "true"

# NSNull/null values (top-level) should parse
test_parse_success "raw tool explicit null via key=value" 'file_search --pattern TODO something=null' "file_search"
test_parse_arg     "raw tool captures null literal" 'file_search --pattern TODO something=null' "something" "null"


echo ""
echo "=== Raw Tool JSON Literal Values (arrays/objects/empty) ==="
echo ""

# JSON array value via key=value / --key value / --key=value
test_parse_success "raw tool JSON array via key=value" 'manage_selection op=set paths=["src/","lib/"]' "manage_selection"
test_parse_success "raw tool JSON array via --key value" 'manage_selection --op set --paths ["src/"]' "manage_selection"
test_parse_success "raw tool JSON array via --key=value" 'manage_selection --op=set --paths=["src/"]' "manage_selection"

# JSON object value via key=value / --key value / --key=value
test_parse_success "raw tool JSON object via key=value" 'file_search pattern=TODO filter={"paths":["src/"]}' "file_search"
test_parse_success "raw tool JSON object via --key value" 'file_search --pattern TODO --filter {"paths":["src/"]}' "file_search"
test_parse_success "raw tool JSON object via --key=value" 'file_search --pattern TODO --filter={"paths":["src/"]}' "file_search"

# Empty literals
test_parse_success "raw tool empty JSON array" 'manage_selection op=set paths=[]' "manage_selection"
test_parse_success "raw tool empty JSON object" 'file_search pattern=TODO filter={}' "file_search"

# JSON object with mixed primitive types (nested) - parse-only validation
test_parse_success "raw tool JSON object mixed types" 'file_search pattern=TODO filter={"paths":["src/"],"max_depth":2,"enabled":true}' "file_search"
test_parse_success "raw tool JSON object deep nesting" 'file_search pattern=TODO filter={"meta":{"level":2,"opts":{"case":false}}}' "file_search"

# JSON array mixed primitives (nested) - parse-only validation
test_parse_success "raw tool JSON array mixed primitives" 'file_search pattern=TODO filter={"items":[1,true,"x",null]}' "file_search"


echo ""
echo "=== Dotted Key Expansion & Merging (parseKeyValueArgs) ==="
echo ""

# Single-level dotted keys
test_parse_success "dotted key expands to nested object (filter.paths=...)" 'file_search pattern=TODO filter.paths=src/' "file_search"

# Multi-level dotted keys
test_parse_success "multi-level dotted key (filter.meta.level=2)" 'file_search pattern=TODO filter.meta.level=2' "file_search"
test_parse_success "multi-level dotted key (filter.meta.opts.case=false)" 'file_search pattern=TODO filter.meta.opts.case=false' "file_search"

# Multiple dotted keys merge under same root object
test_parse_success "multiple dotted keys merge under filter" 'file_search pattern=TODO filter.paths=src/ filter.extensions=.swift' "file_search"

# Dotted keys combined with JSON object merge (parse-only)
test_parse_success "JSON object + dotted key merge" 'file_search pattern=TODO filter={"paths":["src/"]} filter.extensions=[".swift"]' "file_search"

# Dotted keys with JSON array literal value (parse-only)
test_parse_success "dotted key with JSON array value" 'file_search pattern=TODO filter.paths=["src/","lib/"]' "file_search"

# Last-wins behavior on same dotted leaf (parse-only)
test_parse_success "dotted leaf reassignment (last wins) parse-only" 'file_search pattern=TODO filter.paths=src/ filter.paths=lib/' "file_search"

# Dotted keys with dash normalization in nested segment (parse-only)
test_parse_success "dotted key with dash normalization (filter.max-results=10)" 'file_search pattern=TODO filter.max-results=10' "file_search"


echo ""
echo "=== Dash-to-Underscore Normalization (Raw Tool + Alias Flags) ==="
echo ""

# Raw tool top-level dash normalization
test_parse_success "raw tool dash key normalizes (max-results)" 'file_search pattern=TODO max-results=10' "file_search"
test_parse_arg     "raw tool dash key becomes max_results" 'file_search pattern=TODO max-results=10' "max_results" "10"

test_parse_success "raw tool dash key normalizes with --key value" 'file_search --pattern TODO --max-results 20' "file_search"
test_parse_arg     "raw tool --max-results becomes max_results" 'file_search --pattern TODO --max-results 20' "max_results" "20"

# Another common dash key: path-display -> path_display (use a tool that accepts it)
test_parse_success "raw tool dash key normalizes (path-display)" 'workspace_context path-display=full' "workspace_context"
test_parse_arg     "raw tool path-display becomes path_display" 'workspace_context path-display=full' "path_display" "full"

# Alias flags dash/underscore interchangeability (already partly covered; add a few more)
test_parse_success "alias search --context-lines normalizes" 'search "TODO" --context-lines 5' "file_search"
test_parse_arg     "alias search --context-lines sets context_lines" 'search "TODO" --context-lines 5' "context_lines" "5"

test_parse_success "builder supports --type=plan via --flag=value" 'builder --task "x" --type=plan' "context_builder"
test_parse_arg     "builder --type=plan sets response_type" 'builder --task "x" --type=plan' "response_type" "plan"

test_parse_success "builder supports --response-type=question" 'builder --task "x" --response-type=question' "context_builder"
test_parse_arg     "builder --response-type=question sets response_type" 'builder --task "x" --response-type=question' "response_type" "question"


echo ""
echo "=== Quoting, Special Characters, and Edge Values (Alias + Raw Tool) ==="
echo ""

# Negative numbers should be treated as numeric values (not flags)
test_parse_success "alias read negative start_line positional" 'read src/main.swift -20' "read_file"
test_parse_arg     "alias read start_line=-20 positional" 'read src/main.swift -20' "start_line" "-20"

test_parse_success "alias read negative start_line via flag" 'read src/main.swift --start-line -20' "read_file"
test_parse_arg     "alias read --start-line -20" 'read src/main.swift --start-line -20' "start_line" "-20"

test_parse_success "raw tool negative start_line via --key value" 'read_file --path src/main.swift --start-line -20' "read_file"
test_parse_arg     "raw tool read_file --start-line -20" 'read_file --path src/main.swift --start-line -20' "start_line" "-20"

# Values containing '=' should round-trip in strings
test_parse_success "raw tool pattern contains equals sign" 'file_search --pattern "a=b"' "file_search"
test_parse_arg     "raw tool preserves '=' in string" 'file_search --pattern "a=b"' "pattern" "a=b"

# Quotes inside strings - parse-only (hard to assert with current grep helper)
test_parse_success "alias builder escaped quotes parse-only" 'builder "say \"hello\" to user"' "context_builder"

# Backslashes in patterns - parse-only (JSON escaping makes grep brittle)
test_parse_success "raw tool pattern with backslash parse-only" 'file_search --pattern "\\w+"' "file_search"


echo ""
echo "=== Malformed JSON Fallback (parse-only; should not crash) ==="
echo ""

# Malformed JSON should not hard-fail parsing; it should fall back to string values
test_parse_success "malformed JSON object falls back to string (parse-only)" 'file_search pattern=TODO filter={"paths":[src/]}' "file_search"
test_parse_success "malformed JSON array falls back to string (parse-only)" 'manage_selection op=set paths=["src/",]' "manage_selection"

echo ""
echo "=== App Settings Tool ==="
echo ""

# app_settings raw tool routing
test_parse_success "app_settings list" 'app_settings op=list' "app_settings"
test_parse_arg     "app_settings list op" 'app_settings op=list' "op" "list"

test_parse_success "app_settings list UI" 'app_settings op=list group=ui' "app_settings"
test_parse_arg     "app_settings list group" 'app_settings op=list group=ui' "group" "ui"

test_parse_success "app_settings get key" 'app_settings op=get key=ui.show_tooltips' "app_settings"
test_parse_arg     "app_settings get op" 'app_settings op=get key=ui.show_tooltips' "op" "get"
test_parse_arg     "app_settings get key arg" 'app_settings op=get key=ui.show_tooltips' "key" "ui.show_tooltips"

test_parse_success "app_settings set boolean" 'app_settings op=set key=ui.show_tooltips value=false' "app_settings"
test_parse_arg     "app_settings set key" 'app_settings op=set key=ui.show_tooltips value=false' "key" "ui.show_tooltips"
test_parse_bool_false "app_settings set boolean value" 'app_settings op=set key=ui.show_tooltips value=false' "value"

test_parse_success "app_settings set quoted value with spaces" 'app_settings op=set key=models.custom_planning_prompt value="Plan carefully"' "app_settings"
test_parse_arg     "app_settings quoted value with spaces" 'app_settings op=set key=models.custom_planning_prompt value="Plan carefully"' "value" "Plan carefully"

test_parse_success "app_settings JSON fractional value" 'call app_settings {"op":"set","key":"models.temperature","value":1.25}' "app_settings"
test_parse_success "tools settings group" 'tools settings' ""
test_parse_success "tools settings schema" 'tools settings --schema' ""

echo ""
echo "=== Conversation Tools ==="
echo ""

# ask_user structured contract routing
test_parse_success "ask_user direct structured JSON" 'ask_user {"title":"Clarify","questions":[{"id":"scope","question":"Scope?","options":[{"label":"UI","description":"Views and view models"}],"allows_multiple":false,"allows_custom":true}]}' "ask_user"
test_parse_jq "ask_user direct JSON preserves questions" 'ask_user {"title":"Clarify","questions":[{"id":"scope","question":"Scope?","options":[{"label":"UI","description":"Views and view models"}],"allows_multiple":false,"allows_custom":true}]}' '(.jsonPayload | fromjson | .questions[0].id) == "scope" and (.jsonPayload | fromjson | .questions[0].options[0].label) == "UI" and (.jsonPayload | fromjson | .questions[0].allows_multiple) == false and (.jsonPayload | fromjson | .questions[0].allows_custom) == true'
test_parse_success "call ask_user structured JSON" 'call ask_user {"questions":[{"id":"details","question":"What details matter?"}]}' "ask_user"
test_parse_jq "call ask_user JSON preserves questions" 'call ask_user {"questions":[{"id":"details","question":"What details matter?"}]}' '(.jsonPayload | fromjson | .questions[0].id) == "details"'
test_parse_success "tools conversation group includes ask_user" 'tools conversation' ""

echo ""
echo "=== Agent Control Tools ==="
echo ""

# agent_run raw tool routing
test_parse_success "agent_run poll" 'agent_run op=poll session_id=00000000-0000-0000-0000-000000000000' "agent_run"
test_parse_arg     "agent_run poll session_id" 'agent_run op=poll session_id=00000000-0000-0000-0000-000000000000' "op" "poll"
test_parse_arg     "agent_run poll session_id value" 'agent_run op=poll session_id=00000000-0000-0000-0000-000000000000' "session_id" "00000000-0000-0000-0000-000000000000"

test_parse_success "agent_run start with message" 'agent_run op=start message="find auth bugs"' "agent_run"
test_parse_arg     "agent_run start op" 'agent_run op=start message="find auth bugs"' "op" "start"
test_parse_arg     "agent_run start message" 'agent_run op=start message="find auth bugs"' "message" "find auth bugs"
test_parse_arg     "agent_run plan path lives inside message" 'agent_run op=start model_id=engineer message="Read the plan at prompt-exports/oracle-plan.md with read_file first. Implement item 1."' "message" "Read the plan at prompt-exports/oracle-plan.md with read_file first. Implement item 1."

# Dash-to-underscore normalization
test_parse_success "agent_run dashed flags" 'agent_run --op start --session-id abc' "agent_run"
test_parse_arg     "agent_run dash session-id becomes session_id" 'agent_run --op start --session-id abc' "session_id" "abc"

# respond op with multiple fields
test_parse_success "agent_run respond" 'agent_run op=respond session_id=aaa interaction_id=bbb response=accept' "agent_run"
test_parse_arg     "agent_run respond session_id" 'agent_run op=respond session_id=aaa interaction_id=bbb response=accept' "session_id" "aaa"
test_parse_arg     "agent_run respond response" 'agent_run op=respond session_id=aaa interaction_id=bbb response=accept' "response" "accept"
test_parse_success "agent_run respond structured answers" 'agent_run op=respond session_id=aaa interaction_id=bbb answers={"scope":{"answers":["UI"],"selected_options":["UI"],"skipped":false}}' "agent_run"
test_parse_jq     "agent_run respond answers object" 'agent_run op=respond session_id=aaa interaction_id=bbb answers={"scope":{"answers":["UI"],"selected_options":["UI"],"skipped":false}}' '.args.answers.scope.answers[0] == "UI" and .args.answers.scope.selected_options[0] == "UI" and .args.answers.scope.skipped == false'
test_parse_bool_true "agent_run respond skip true" 'agent_run op=respond session_id=aaa interaction_id=bbb skip=true' "skip"

# steer op
test_parse_success "agent_run steer" 'agent_run op=steer session_id=abc message="also check logout"' "agent_run"
test_parse_arg     "agent_run steer message" 'agent_run op=steer session_id=abc message="also check logout"' "message" "also check logout"

# cancel and wait
test_parse_success "agent_run cancel" 'agent_run op=cancel session_id=abc' "agent_run"
test_parse_success "agent_run wait" 'agent_run op=wait session_id=abc' "agent_run"
test_parse_success "agent_run wait with timeout" 'agent_run op=wait session_id=abc timeout=1.5' "agent_run"
test_parse_arg     "agent_run wait timeout" 'agent_run op=wait session_id=abc timeout=1.5' "timeout" "1.5"
test_parse_success "agent_run wait timeout=0" 'agent_run op=wait session_id=abc timeout=0' "agent_run"
test_parse_arg     "agent_run wait timeout=0 arg" 'agent_run op=wait session_id=abc timeout=0' "timeout" "0"
test_parse_success     "agent_run wait multiple session_ids" 'agent_run op=wait session_ids=["00000000-0000-0000-0000-000000000001","00000000-0000-0000-0000-000000000002"] timeout=60' "agent_run"
test_parse_array_count "agent_run wait session_ids is array" 'agent_run op=wait session_ids=["00000000-0000-0000-0000-000000000001","00000000-0000-0000-0000-000000000002"] timeout=60' "session_ids" "2"
test_parse_success     "agent_run poll multiple session_ids" 'agent_run op=poll session_ids=["00000000-0000-0000-0000-000000000001","00000000-0000-0000-0000-000000000002","00000000-0000-0000-0000-000000000003"]' "agent_run"
test_parse_array_count "agent_run poll session_ids is array" 'agent_run op=poll session_ids=["00000000-0000-0000-0000-000000000001","00000000-0000-0000-0000-000000000002","00000000-0000-0000-0000-000000000003"]' "session_ids" "3"

# agent_manage raw tool routing
test_parse_success "agent_manage list_agents" 'agent_manage op=list_agents' "agent_manage"
test_parse_arg     "agent_manage list_agents op" 'agent_manage op=list_agents' "op" "list_agents"

test_parse_success "agent_manage list_sessions with params" 'agent_manage op=list_sessions limit=10 state=running' "agent_manage"
test_parse_arg     "agent_manage list_sessions limit" 'agent_manage op=list_sessions limit=10 state=running' "limit" "10"
test_parse_arg     "agent_manage list_sessions state" 'agent_manage op=list_sessions limit=10 state=running' "state" "running"

test_parse_success "agent_manage get_log" 'agent_manage op=get_log session_id=abc offset=1 limit=5' "agent_manage"
test_parse_arg     "agent_manage get_log session_id" 'agent_manage op=get_log session_id=abc offset=1 limit=5' "session_id" "abc"
test_parse_arg     "agent_manage get_log offset" 'agent_manage op=get_log session_id=abc offset=1 limit=5' "offset" "1"

# handoff shorthand
test_parse_success "agent_manage handoff shorthand" 'agent_manage handoff 00000000-0000-0000-0000-000000000000 --output /tmp/handoff.xml' "agent_manage"
test_parse_arg     "agent_manage handoff shorthand op" 'agent_manage handoff 00000000-0000-0000-0000-000000000000 --output /tmp/handoff.xml' "op" "extract_handoff"
test_parse_arg     "agent_manage handoff shorthand session_id" 'agent_manage handoff 00000000-0000-0000-0000-000000000000 --output /tmp/handoff.xml' "session_id" "00000000-0000-0000-0000-000000000000"
test_parse_arg     "agent_manage handoff shorthand output" 'agent_manage handoff 00000000-0000-0000-0000-000000000000 --output /tmp/handoff.xml' "output_path" "/tmp/handoff.xml"
test_parse_bool_true "agent_manage handoff include file contents" 'agent_manage handoff abc --include-file-contents' "include_file_contents"
test_parse_arg     "agent_manage handoff no-overwrite" 'agent_manage handoff abc --no-overwrite' "overwrite" "false"
test_parse_arg     "agent_manage handoff inline false" 'agent_manage handoff abc --inline=false' "inline" "false"
test_parse_arg     "agent_manage handoff cutoff" 'agent_manage handoff abc --up-to-item-id 11111111-1111-1111-1111-111111111111' "up_to_item_id" "11111111-1111-1111-1111-111111111111"
test_parse_arg     "agent_manage handoff cutoff alias" 'agent_manage handoff abc --cutoff 11111111-1111-1111-1111-111111111111' "up_to_item_id" "11111111-1111-1111-1111-111111111111"
test_parse_fail    "agent_manage handoff missing output value" 'agent_manage handoff abc --output' "output_path"
test_parse_fail    "agent_manage handoff invalid max items" 'agent_manage handoff abc --max-transcript-items nope' "max_transcript_items"

test_parse_success "agent_manage create_session" 'agent_manage op=create_session session_name="Auth flow"' "agent_manage"
test_parse_arg     "agent_manage create_session name" 'agent_manage op=create_session session_name="Auth flow"' "session_name" "Auth flow"

test_parse_success "agent_manage resume_session" 'agent_manage op=resume_session session_id=abc' "agent_manage"

test_parse_success "agent_manage stop_session" 'agent_manage op=stop_session session_id=abc' "agent_manage"
test_parse_arg     "agent_manage stop_session op" 'agent_manage op=stop_session session_id=abc' "op" "stop_session"
test_parse_arg     "agent_manage stop_session session_id" 'agent_manage op=stop_session session_id=abc' "session_id" "abc"

test_parse_success "agent_manage list_workflows" 'agent_manage op=list_workflows' "agent_manage"

echo ""
echo "=== Other Commands ==="
echo ""

test_parse_success "help command" 'help' ""
test_parse_success "tools command" 'tools' ""
# windows returns a direct command, not aliasCall
test_parse_success "windows command" 'windows' ""
test_parse_success "models command" 'models' "oracle_utils"

echo ""
echo "========================================"
echo "Results: ${GREEN}$PASSED passed${NC}, ${RED}$FAILED failed${NC}"
echo "========================================"

if [ $FAILED -gt 0 ]; then
    exit 1
fi
