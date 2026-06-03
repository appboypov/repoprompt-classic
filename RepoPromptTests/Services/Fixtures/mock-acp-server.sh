#!/bin/sh
set -eu

LOG_FILE="${ACP_TEST_LOG:-}"
SCENARIO="${ACP_TEST_SCENARIO:-bootstrap}"
SESSION_ID="${ACP_TEST_SESSION_ID:-mock-session}"
TOOL_UPDATE_STATUS="${ACP_TEST_TOOL_UPDATE_STATUS:-in_progress}"
PERMISSION_ID=900
PENDING_PROMPT_ID=""
PENDING_LOAD_ID=""
SAW_PERMISSION_RESPONSE=0
SAW_CANCEL=0
PROMPT_COUNT=0
CURRENT_MODE_ID="${ACP_TEST_CURRENT_MODE_ID:-default}"
if [ "${ACP_TEST_AVAILABLE_MODES_JSON+x}" = "x" ]; then
	AVAILABLE_MODES_JSON="$ACP_TEST_AVAILABLE_MODES_JSON"
else
	AVAILABLE_MODES_JSON='[{"id":"default"},{"id":"yolo"},{"id":"agent"},{"id":"plan"},{"id":"ask"}]'
fi
SESSION_WAS_LOADED=0
SAW_LOAD_REQUEST=0
MODELS_JSON="${ACP_TEST_MODELS_JSON:-}"
CONFIG_OPTIONS_JSON="${ACP_TEST_CONFIG_OPTIONS_JSON:-}"
PROMPT_USAGE_JSON="${ACP_TEST_PROMPT_USAGE_JSON:-}"
PERMISSION_TITLE="${ACP_TEST_PERMISSION_TITLE:-Run test command}"
PERMISSION_KIND="${ACP_TEST_PERMISSION_KIND:-execute}"
PERMISSION_RAW_INPUT_JSON="${ACP_TEST_PERMISSION_RAW_INPUT_JSON:-}"
PERMISSION_OPTIONS_JSON="${ACP_TEST_PERMISSION_OPTIONS_JSON:-}"
LOAD_SESSION_SUPPORTED="${ACP_TEST_LOAD_SESSION_SUPPORTED:-true}"
LOAD_ERROR="${ACP_TEST_LOAD_ERROR:-}"
LOAD_ERROR_CODE="${ACP_TEST_LOAD_ERROR_CODE:--32000}"
LOAD_ERROR_DATA_MESSAGE="${ACP_TEST_LOAD_ERROR_DATA_MESSAGE:-}"
NEW_ERROR="${ACP_TEST_NEW_ERROR:-}"
NEW_ERROR_CODE="${ACP_TEST_NEW_ERROR_CODE:--32603}"
NEW_ERROR_DATA_MESSAGE="${ACP_TEST_NEW_ERROR_DATA_MESSAGE:-}"
PROMPT_ERROR="${ACP_TEST_PROMPT_ERROR:-}"
PROMPT_ERROR_CODE="${ACP_TEST_PROMPT_ERROR_CODE:--32603}"
PROMPT_ERROR_DATA_MESSAGE="${ACP_TEST_PROMPT_ERROR_DATA_MESSAGE:-}"
AUTH_METHODS_KIND="${ACP_TEST_AUTH_METHODS_KIND:-gemini}"
LOAD_REPLAY_UPDATES="${ACP_TEST_LOAD_REPLAY_UPDATES:-false}"
GEMINI_CHAT_TMP_DIR="${ACP_TEST_GEMINI_CHAT_TMP_DIR:-}"
GEMINI_DURABLE_SESSION_ID="${ACP_TEST_GEMINI_DURABLE_SESSION_ID:-}"
GEMINI_CHAT_USER_TEXT="${ACP_TEST_GEMINI_CHAT_USER_TEXT:-RepoPrompt mock prompt}"
GEMINI_WORKSPACE_PATH="${ACP_TEST_GEMINI_WORKSPACE_PATH:-}"
GEMINI_CHAT_CONTENT_FORMAT="${ACP_TEST_GEMINI_CHAT_CONTENT_FORMAT:-array}"
GEMINI_WRITE_CHAT_ON_PROMPT="${ACP_TEST_GEMINI_WRITE_CHAT_ON_PROMPT:-false}"

if [ -z "$PERMISSION_RAW_INPUT_JSON" ]; then
	PERMISSION_RAW_INPUT_JSON='{"command":"echo hi"}'
fi
if [ -z "$PERMISSION_OPTIONS_JSON" ]; then
	PERMISSION_OPTIONS_JSON='[{"optionId":"opt-allow-once","kind":"allow_once"},{"optionId":"opt-allow-always","kind":"allow_always"},{"optionId":"opt-reject-once","kind":"reject_once"}]'
fi

if [ "$SCENARIO" = "silent" ]; then
	sleep 5
	exit 0
fi

log_line() {
	if [ -n "$LOG_FILE" ]; then
		printf '%s
' "$1" >> "$LOG_FILE"
	fi
}

send_json() {
	printf '%s
' "$1"
}

extract_id() {
	printf '%s' "$1" | sed -n 's/.*"id":\([^,}]*\).*/\1/p'
}

extract_method() {
	printf '%s' "$1" | sed -n 's/.*"method":"\([^"]*\)".*/\1/p' | sed 's#\\/#/#g'
}

extract_mode_id() {
	printf '%s' "$1" | sed -n 's/.*"modeId":"\([^"]*\)".*/\1/p'
}

extract_config_value() {
	printf '%s' "$1" | sed -n 's/.*"value":"\([^"]*\)".*/\1/p'
}

auth_methods_json() {
	case "$AUTH_METHODS_KIND" in
		cursor)
			printf '[{"id":"cursor_login"}]'
			;;
		none)
			printf '[]'
			;;
		*)
			printf '[{"id":"login_with_google"},{"id":"use_gemini"}]'
			;;
	esac
}

send_initialize_result() {
	id="$1"
	auth_methods="$(auth_methods_json)"
	send_json "{\"jsonrpc\":\"2.0\",\"id\":$id,\"result\":{\"protocolVersion\":1,\"authMethods\":$auth_methods,\"agentCapabilities\":{\"loadSession\":$LOAD_SESSION_SUPPORTED}}}"
}

session_metadata_json() {
	metadata="\"modes\":{\"currentModeId\":\"$CURRENT_MODE_ID\""
	if [ -n "$AVAILABLE_MODES_JSON" ]; then
		metadata="$metadata,\"availableModes\":$AVAILABLE_MODES_JSON"
	fi
	metadata="$metadata}"
	if [ -n "$MODELS_JSON" ]; then
		metadata="$metadata,\"models\":$MODELS_JSON"
	fi
	if [ -n "$CONFIG_OPTIONS_JSON" ]; then
		metadata="$metadata,\"configOptions\":$CONFIG_OPTIONS_JSON"
	fi
	printf '%s' "$metadata"
}

send_session_result() {
	id="$1"
	session_id="$2"
	metadata="$(session_metadata_json)"
	send_json "{\"jsonrpc\":\"2.0\",\"id\":$id,\"result\":{\"sessionId\":\"$session_id\",$metadata}}"
}

send_load_result() {
	id="$1"
	metadata="$(session_metadata_json)"
	send_json "{\"jsonrpc\":\"2.0\",\"id\":$id,\"result\":{$metadata}}"
}

send_empty_result() {
	id="$1"
	send_json "{\"jsonrpc\":\"2.0\",\"id\":$id,\"result\":{}}"
}

send_error_result() {
	id="$1"
	code="$2"
	message="$3"
	data_message="${4:-}"
	if [ -n "$data_message" ]; then
		send_json "{\"jsonrpc\":\"2.0\",\"id\":$id,\"error\":{\"code\":$code,\"message\":\"$message\",\"data\":{\"message\":\"$data_message\"}}}"
	else
		send_json "{\"jsonrpc\":\"2.0\",\"id\":$id,\"error\":{\"code\":$code,\"message\":\"$message\"}}"
	fi
}

write_gemini_chat_file_if_enabled() {
	if [ -z "$GEMINI_CHAT_TMP_DIR" ] || [ "$GEMINI_WRITE_CHAT_ON_PROMPT" != "true" ]; then
		return
	fi
	durable_id="$GEMINI_DURABLE_SESSION_ID"
	if [ -z "$durable_id" ]; then
		durable_id="$SESSION_ID"
	fi
	prefix="$(printf '%s' "$durable_id" | cut -c 1-8)"
	chats_dir="$GEMINI_CHAT_TMP_DIR/mock-project/chats"
	mkdir -p "$chats_dir"
	file="$chats_dir/session-$(date +%s)-$prefix.jsonl"
	now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
	if [ -n "$GEMINI_WORKSPACE_PATH" ]; then
		printf '{"sessionId":"%s","kind":"main","startTime":"%s","lastUpdated":"%s","workspacePath":"%s"}\n' "$durable_id" "$now" "$now" "$GEMINI_WORKSPACE_PATH" > "$file"
	else
		printf '{"sessionId":"%s","kind":"main","startTime":"%s","lastUpdated":"%s"}\n' "$durable_id" "$now" "$now" > "$file"
	fi
	if [ "$GEMINI_CHAT_CONTENT_FORMAT" = "array" ]; then
		printf '{"type":"user","content":[{"text":"%s"}]}\n' "$GEMINI_CHAT_USER_TEXT" >> "$file"
	else
		printf '{"type":"user","content":"%s"}\n' "$GEMINI_CHAT_USER_TEXT" >> "$file"
	fi
}

send_request_result() {
	id="$1"
	stop_reason="$2"
	usage=""
	if [ -n "$PROMPT_USAGE_JSON" ]; then
		usage=",\"usage\":$PROMPT_USAGE_JSON"
	fi
	send_json "{\"jsonrpc\":\"2.0\",\"id\":$id,\"result\":{\"stopReason\":\"$stop_reason\"$usage}}"
}

send_config_option_result() {
	id="$1"
	current_value="$2"
	send_json "{\"jsonrpc\":\"2.0\",\"id\":$id,\"result\":{\"configOptions\":[{\"id\":\"model\",\"name\":\"Model\",\"category\":\"model\",\"type\":\"select\",\"currentValue\":\"$current_value\",\"options\":[{\"value\":\"anthropic/claude-sonnet-4\",\"name\":\"Anthropic/Claude Sonnet 4\"},{\"value\":\"openai/gpt-5\",\"name\":\"OpenAI/GPT-5\"}]}]}}"
}

send_tool_call() {
	tool_call_id="$1"
	send_json "{\"jsonrpc\":\"2.0\",\"method\":\"session/update\",\"params\":{\"sessionId\":\"$SESSION_ID\",\"update\":{\"sessionUpdate\":\"tool_call\",\"toolCallId\":\"$tool_call_id\",\"title\":\"read_file\",\"rawInput\":{\"path\":\"README.md\"}}}}"
}

send_tool_call_update() {
	tool_call_id="$1"
	status="$2"
	case "$status" in
		completed|failed)
			send_json "{\"jsonrpc\":\"2.0\",\"method\":\"session/update\",\"params\":{\"sessionId\":\"$SESSION_ID\",\"update\":{\"sessionUpdate\":\"tool_call_update\",\"toolCallId\":\"$tool_call_id\",\"status\":\"$status\",\"title\":\"read_file\",\"rawInput\":{\"path\":\"README.md\"},\"rawOutput\":{\"content\":\"mock file contents\",\"status\":\"$status\"}}}}"
			;;
		in_progress)
			send_json "{\"jsonrpc\":\"2.0\",\"method\":\"session/update\",\"params\":{\"sessionId\":\"$SESSION_ID\",\"update\":{\"sessionUpdate\":\"tool_call_update\",\"toolCallId\":\"$tool_call_id\",\"status\":\"in_progress\",\"title\":\"Reading README.md\"}}}"
			;;
		*)
			send_json "{\"jsonrpc\":\"2.0\",\"method\":\"session/update\",\"params\":{\"sessionId\":\"$SESSION_ID\",\"update\":{\"sessionUpdate\":\"tool_call_update\",\"toolCallId\":\"$tool_call_id\",\"status\":\"$status\",\"title\":\"read_file\"}}}"
			;;
	esac
}

send_prompt_updates() {
	send_json "{\"jsonrpc\":\"2.0\",\"method\":\"session/update\",\"params\":{\"sessionId\":\"$SESSION_ID\",\"update\":{\"sessionUpdate\":\"agent_message_chunk\",\"content\":{\"type\":\"text\",\"text\":\"hello from mock acp\"}}}}"
	send_tool_call "tool-1"
	send_tool_call_update "tool-1" "in_progress"
	send_tool_call_update "tool-1" "completed"
}

send_load_replay_updates() {
	send_json "{\"jsonrpc\":\"2.0\",\"method\":\"session/update\",\"params\":{\"sessionId\":\"$SESSION_ID\",\"update\":{\"sessionUpdate\":\"user_message_chunk\",\"content\":{\"type\":\"text\",\"text\":\"old replay user text\"}}}}"
	send_json "{\"jsonrpc\":\"2.0\",\"method\":\"session/update\",\"params\":{\"sessionId\":\"$SESSION_ID\",\"update\":{\"sessionUpdate\":\"agent_message_chunk\",\"content\":{\"type\":\"text\",\"text\":\"old replay assistant text\"}}}}"
	send_json "{\"jsonrpc\":\"2.0\",\"method\":\"session/update\",\"params\":{\"sessionId\":\"$SESSION_ID\",\"update\":{\"sessionUpdate\":\"agent_thought_chunk\",\"content\":{\"type\":\"text\",\"text\":\"old replay reasoning text\"}}}}"
	send_tool_call "old-replay-tool"
	send_tool_call_update "old-replay-tool" "completed"
	send_json "{\"jsonrpc\":\"2.0\",\"method\":\"session/update\",\"params\":{\"sessionId\":\"$SESSION_ID\",\"update\":{\"sessionUpdate\":\"session_info_update\",\"title\":\"old replay status text\"}}}"
	send_json "{\"jsonrpc\":\"2.0\",\"method\":\"session/update\",\"params\":{\"sessionId\":\"$SESSION_ID\",\"update\":{\"sessionUpdate\":\"available_commands_update\",\"commands\":[{\"name\":\"old-replay-command\"}]}}}"
	send_json "{\"jsonrpc\":\"2.0\",\"method\":\"session/update\",\"params\":{\"sessionId\":\"$SESSION_ID\",\"update\":{\"sessionUpdate\":\"plan\",\"entries\":[{\"content\":\"old replay plan text\",\"status\":\"pending\"}]}}}"
	send_json "{\"jsonrpc\":\"2.0\",\"method\":\"session/update\",\"params\":{\"sessionId\":\"$SESSION_ID\",\"update\":{\"sessionUpdate\":\"usage_update\",\"used\":111,\"size\":222,\"cost\":{\"amount\":0.33,\"currency\":\"USD\"}}}}"
}

send_success_content() {
	send_json "{\"jsonrpc\":\"2.0\",\"method\":\"session/update\",\"params\":{\"sessionId\":\"$SESSION_ID\",\"update\":{\"sessionUpdate\":\"agent_message_chunk\",\"content\":{\"type\":\"text\",\"text\":\"OK from success scenario\"}}}}"
}

send_permission_request() {
	send_json "{\"jsonrpc\":\"2.0\",\"id\":$PERMISSION_ID,\"method\":\"session/request_permission\",\"params\":{\"sessionId\":\"$SESSION_ID\",\"toolCall\":{\"toolCallId\":\"permission-tool-1\",\"title\":\"$PERMISSION_TITLE\",\"kind\":\"$PERMISSION_KIND\",\"rawInput\":$PERMISSION_RAW_INPUT_JSON},\"options\":$PERMISSION_OPTIONS_JSON}}"
}

handle_prompt() {
	id="$1"
	PENDING_PROMPT_ID="$id"
	PROMPT_COUNT=$((PROMPT_COUNT + 1))
	write_gemini_chat_file_if_enabled
	case "$SCENARIO" in
		prompt)
			send_prompt_updates
			send_request_result "$PENDING_PROMPT_ID" "end_turn"
			PENDING_PROMPT_ID=""
			;;
		success|bootstrap)
			send_success_content
			send_request_result "$PENDING_PROMPT_ID" "end_turn"
			PENDING_PROMPT_ID=""
			;;
		json_reasoning_before_delayed_content)
			send_json "{\"jsonrpc\":\"2.0\",\"method\":\"session/update\",\"params\":{\"sessionId\":\"$SESSION_ID\",\"update\":{\"sessionUpdate\":\"agent_thought_chunk\",\"content\":{\"type\":\"text\",\"text\":\"{\\\"summary\\\":\\\"thinking\\\"}\"}}}}"
			sleep 1
			send_json "{\"jsonrpc\":\"2.0\",\"method\":\"session/update\",\"params\":{\"sessionId\":\"$SESSION_ID\",\"update\":{\"sessionUpdate\":\"agent_message_chunk\",\"content\":{\"type\":\"text\",\"text\":\"JSON_REASONING_DONE\"}}}}"
			send_request_result "$PENDING_PROMPT_ID" "end_turn"
			PENDING_PROMPT_ID=""
			;;
		delayed_success)
			sleep 1
			send_success_content
			send_request_result "$PENDING_PROMPT_ID" "end_turn"
			PENDING_PROMPT_ID=""
			;;
		streaming_progress_then_complete)
			send_success_content
			sleep 1
			send_success_content
			sleep 1
			send_request_result "$PENDING_PROMPT_ID" "end_turn"
			PENDING_PROMPT_ID=""
			;;
		tool_call_delayed_update_then_complete)
			send_tool_call "tool-timeout-1"
			sleep 1
			send_tool_call_update "tool-timeout-1" "completed"
			send_request_result "$PENDING_PROMPT_ID" "end_turn"
			PENDING_PROMPT_ID=""
			;;
		tool_call_delayed_update_then_hang)
			send_tool_call "tool-timeout-1"
			sleep 1
			send_tool_call_update "tool-timeout-1" "$TOOL_UPDATE_STATUS"
			;;
		empty_opencode_completion)
			send_json "{\"jsonrpc\":\"2.0\",\"method\":\"session/update\",\"params\":{\"sessionId\":\"$SESSION_ID\",\"update\":{\"sessionUpdate\":\"usage_update\",\"used\":0,\"size\":262000,\"cost\":{\"amount\":0,\"currency\":\"USD\"}}}}"
			send_request_result "$PENDING_PROMPT_ID" "end_turn"
			PENDING_PROMPT_ID=""
			;;
		permission|permission_then_complete|cancel)
			send_permission_request
			;;
		steering_cancel_then_success)
			if [ "$PROMPT_COUNT" = "1" ]; then
				send_permission_request
			else
				send_success_content
				send_request_result "$PENDING_PROMPT_ID" "end_turn"
				PENDING_PROMPT_ID=""
			fi
			;;
		no_prompt_response)
			send_success_content
			if [ "$SAW_LOAD_REQUEST" = "1" ]; then
				send_request_result "$PENDING_PROMPT_ID" "end_turn"
				PENDING_PROMPT_ID=""
			fi
			;;
		*)
			send_request_result "$PENDING_PROMPT_ID" "end_turn"
			PENDING_PROMPT_ID=""
			;;
	esac
}

while IFS= read -r line; do
	log_line "$line"
	method="$(extract_method "$line")"
	if [ -n "$method" ]; then
		id="$(extract_id "$line")"
		case "$method" in
			initialize)
				send_initialize_result "$id"
				;;
			authenticate)
				send_empty_result "$id"
				;;
				session/new)
				if [ -n "$NEW_ERROR" ]; then
					send_error_result "$id" "$NEW_ERROR_CODE" "$NEW_ERROR" "$NEW_ERROR_DATA_MESSAGE"
				else
					send_session_result "$id" "$SESSION_ID"
					if [ "$SCENARIO" = "exit_after_bootstrap" ]; then
						exit 0
					fi
				fi
				;;
		session/load)
			SAW_LOAD_REQUEST=1
			if [ -n "$LOAD_ERROR" ]; then
				send_error_result "$id" "$LOAD_ERROR_CODE" "$LOAD_ERROR" "$LOAD_ERROR_DATA_MESSAGE"
			else
				PENDING_LOAD_ID="$id"
				SESSION_WAS_LOADED=1
				if [ "$LOAD_REPLAY_UPDATES" = "true" ]; then
					send_load_replay_updates
				fi
				send_load_result "$id"
				if [ "$SCENARIO" = "exit_after_bootstrap" ]; then
					exit 0
				fi
			fi
			;;
			session/set_mode)
				mode_id="$(extract_mode_id "$line")"
				if [ -n "$mode_id" ]; then
					CURRENT_MODE_ID="$mode_id"
				fi
				send_empty_result "$id"
				;;
			session/set_config_option)
				config_value="$(extract_config_value "$line")"
				if [ -z "$config_value" ]; then
					config_value="openai/gpt-5"
				fi
				send_config_option_result "$id" "$config_value"
				;;
			session/prompt)
				if [ -n "$PROMPT_ERROR" ]; then
					send_error_result "$id" "$PROMPT_ERROR_CODE" "$PROMPT_ERROR" "$PROMPT_ERROR_DATA_MESSAGE"
				else
					handle_prompt "$id"
				fi
				;;
			session/cancel)
				SAW_CANCEL=1
				if { [ "$SCENARIO" = "cancel" ] || [ "$SCENARIO" = "steering_cancel_then_success" ]; } && [ "$SAW_PERMISSION_RESPONSE" = "1" ] && [ -n "$PENDING_PROMPT_ID" ]; then
					send_request_result "$PENDING_PROMPT_ID" "cancelled"
					PENDING_PROMPT_ID=""
				fi
				;;
		esac
	else
		id="$(extract_id "$line")"
		if [ "$id" = "$PERMISSION_ID" ]; then
			SAW_PERMISSION_RESPONSE=1
			case "$SCENARIO" in
				permission|permission_then_complete)
					if [ -n "$PENDING_PROMPT_ID" ]; then
						send_success_content
						send_request_result "$PENDING_PROMPT_ID" "end_turn"
						PENDING_PROMPT_ID=""
					fi
					;;
				cancel|steering_cancel_then_success)
					if [ "$SAW_CANCEL" = "1" ] && [ -n "$PENDING_PROMPT_ID" ]; then
						send_request_result "$PENDING_PROMPT_ID" "cancelled"
						PENDING_PROMPT_ID=""
					fi
					;;
			esac
		fi
	fi
done
