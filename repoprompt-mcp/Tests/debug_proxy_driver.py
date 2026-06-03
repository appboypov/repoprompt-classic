#!/usr/bin/env python3
"""
Raw proxy JSON-RPC driver for RepoPrompt DEBUG diagnostics live tests.

Launches rp-cli-debug/repoprompt-mcp in proxy mode (no args), drives newline-delimited
JSON-RPC over stdin/stdout, and emits a compact JSON summary. Intended for the
focused BombSquad debug diagnostics script.
"""

from __future__ import annotations

import argparse
import json
import os
import select
import signal
import subprocess
import sys
import threading
import time
from typing import Any, Dict, List, Optional, Sequence

HIDDEN_TOOL = "__repoprompt_debug_diagnostics"


class ScenarioFailure(RuntimeError):
    pass


class RawProxy:
    def __init__(self, cli: str, timeout: float = 10.0, env: Optional[Dict[str, str]] = None, verbose: bool = False):
        self.cli = cli
        self.timeout = timeout
        self.verbose = verbose
        proc_env = os.environ.copy()
        if env:
            proc_env.update(env)
        stdin_read_fd, stdin_write_fd = os.pipe()
        self._stdin_write_fd: Optional[int] = stdin_write_fd
        self.proc = subprocess.Popen(
            [cli],
            stdin=stdin_read_fd,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            bufsize=1,
            env=proc_env,
        )
        os.close(stdin_read_fd)
        self.stderr_lines: List[str] = []
        self._initialize_counter = 0
        self._stderr_thread = threading.Thread(target=self._drain_stderr, daemon=True)
        self._stderr_thread.start()

    def _drain_stderr(self) -> None:
        if self.proc.stderr is None:
            return
        try:
            for line in self.proc.stderr:
                self.stderr_lines.append(line)
        except Exception as exc:  # pragma: no cover - diagnostic only
            self.stderr_lines.append(f"<stderr reader failed: {exc}>\n")

    @property
    def pid(self) -> int:
        return int(self.proc.pid)

    @property
    def stderr_text(self) -> str:
        return "".join(self.stderr_lines)

    def log(self, message: str) -> None:
        if self.verbose:
            print(f"[driver] {message}", file=sys.stderr)

    def send_obj(self, obj: Any) -> None:
        line = json.dumps(obj, separators=(",", ":"))
        self.send_line(line)

    def send_line(self, line: str) -> None:
        if self._stdin_write_fd is None:
            raise ScenarioFailure("proxy stdin is unavailable")
        self.log(f"→ {line[:500]}")
        try:
            os.write(self._stdin_write_fd, (line + "\n").encode("utf-8"))
        except BrokenPipeError as exc:
            raise ScenarioFailure(f"proxy stdin closed while sending frame: {exc}") from exc

    def read_line(self, timeout: Optional[float] = None) -> Optional[str]:
        if self.proc.stdout is None or self.proc.stdout.closed:
            return None
        deadline = time.monotonic() + (self.timeout if timeout is None else timeout)
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                return None
            ready, _, _ = select.select([self.proc.stdout], [], [], remaining)
            if not ready:
                return None
            line = self.proc.stdout.readline()
            if line == "":
                return None
            line = line.rstrip("\n")
            self.log(f"← {line[:500]}")
            return line

    def read_json(self, timeout: Optional[float] = None) -> Any:
        line = self.read_line(timeout=timeout)
        if line is None:
            raise ScenarioFailure(f"timed out waiting for JSON line; proc_poll={self.proc.poll()} stderr={self.stderr_text[-500:]}")
        try:
            return json.loads(line)
        except json.JSONDecodeError as exc:
            raise ScenarioFailure(f"stdout line was not JSON: {line[:500]}") from exc

    def read_response(self, response_id: Optional[str] = None, timeout: Optional[float] = None) -> Dict[str, Any]:
        response = self.try_read_response(response_id=response_id, timeout=timeout)
        if response is None:
            raise ScenarioFailure(f"timed out waiting for response id={response_id}; stderr={self.stderr_text[-500:]}")
        return response

    def try_read_response(self, response_id: Optional[str] = None, timeout: Optional[float] = None) -> Optional[Dict[str, Any]]:
        deadline = time.monotonic() + (self.timeout if timeout is None else timeout)
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                return None
            try:
                message = self.read_json(timeout=remaining)
            except ScenarioFailure:
                return None
            if not isinstance(message, dict):
                if response_id is None:
                    return {"batch": message}
                continue
            if response_id is None or message.get("id") == response_id:
                return message

    def assert_no_stdout(self, timeout: float = 0.3) -> None:
        line = self.read_line(timeout=timeout)
        if line is not None:
            raise ScenarioFailure(f"expected no stdout, got: {line[:500]}")

    def initialize(self, client_name: str = "RepoPrompt CLI (Interactive)", request_id: Optional[str] = None, timeout: Optional[float] = None) -> Dict[str, Any]:
        self._initialize_counter += 1
        rid = request_id or f"init-{self._initialize_counter}"
        self.send_obj({
            "jsonrpc": "2.0",
            "id": rid,
            "method": "initialize",
            "params": {
                "capabilities": {},
                "clientInfo": {"name": client_name, "version": "1.0"},
            },
        })
        response = self.read_response(rid, timeout=timeout)
        if "error" in response:
            raise ScenarioFailure(f"initialize failed: {response}")
        self.send_obj({"jsonrpc": "2.0", "method": "notifications/initialized"})
        return response

    def call_tool(self, name: str, args: Dict[str, Any], request_id: str = "tool-1", timeout: Optional[float] = None) -> Dict[str, Any]:
        self.send_obj({
            "jsonrpc": "2.0",
            "id": request_id,
            "method": "tools/call",
            "params": {"name": name, "arguments": args},
        })
        response = self.read_response(request_id, timeout=timeout)
        return extract_tool_payload(response)

    def call_debug(self, args: Dict[str, Any], request_id: str = "debug-1", timeout: Optional[float] = None) -> Dict[str, Any]:
        payload = self.call_tool(HIDDEN_TOOL, args, request_id=request_id, timeout=timeout)
        if not payload.get("ok"):
            raise ScenarioFailure(f"debug call failed: {payload}")
        return payload

    def call_bind_context(self, args: Dict[str, Any], request_id: str = "bind-1", timeout: Optional[float] = None) -> Dict[str, Any]:
        payload = dict(args)
        payload["_rawJSON"] = True
        return self.call_tool("bind_context", payload, request_id=request_id, timeout=timeout)

    def close_stdin(self) -> None:
        if self._stdin_write_fd is not None:
            try:
                os.close(self._stdin_write_fd)
            finally:
                self._stdin_write_fd = None

    def close_stdout_reader(self) -> None:
        if self.proc.stdout is not None and not self.proc.stdout.closed:
            self.proc.stdout.close()

    def terminate(self) -> None:
        if self.proc.poll() is None:
            self.proc.kill()

    def wait(self, timeout: Optional[float] = None) -> int:
        try:
            return self.proc.wait(timeout=self.timeout if timeout is None else timeout)
        except subprocess.TimeoutExpired as exc:
            raise ScenarioFailure(f"proxy did not exit within timeout; stderr={self.stderr_text[-500:]}") from exc

    def cleanup(self) -> None:
        try:
            self.close_stdin()
        except Exception:
            pass
        if self.proc.poll() is None:
            try:
                self.proc.terminate()
                self.proc.wait(timeout=2)
            except Exception:
                try:
                    self.proc.kill()
                except Exception:
                    pass
        try:
            if self.proc.stdout is not None and not self.proc.stdout.closed:
                self.proc.stdout.close()
        except Exception:
            pass


def fail(message: str) -> None:
    raise ScenarioFailure(message)


def extract_tool_payload(response: Dict[str, Any]) -> Dict[str, Any]:
    if "error" in response:
        fail(f"JSON-RPC response error: {response['error']}")
    result = response.get("result")
    if not isinstance(result, dict):
        fail(f"missing result object: {response}")
    content = result.get("content")
    if not isinstance(content, list) or not content:
        fail(f"missing tool content: {response}")
    text = content[0].get("text") if isinstance(content[0], dict) else None
    if not isinstance(text, str):
        fail(f"missing text content: {response}")
    try:
        payload = json.loads(text)
    except json.JSONDecodeError:
        return {"text": text}
    if not isinstance(payload, dict):
        fail(f"tool payload was not an object: {payload}")
    return payload


def extract_debug_payload(response: Dict[str, Any]) -> Dict[str, Any]:
    payload = extract_tool_payload(response)
    if "text" in payload:
        fail(f"hidden tool text was not JSON: {payload['text'][:500]}")
    return payload


def parse_cli_json(output: str) -> Dict[str, Any]:
    stripped = output.strip()
    try:
        value = json.loads(stripped)
    except json.JSONDecodeError:
        start = stripped.find("{")
        end = stripped.rfind("}")
        if start < 0 or end <= start:
            fail(f"CLI output did not contain JSON: {output[-500:]}")
        value = json.loads(stripped[start:end + 1])
    if isinstance(value, dict) and "content" in value:
        content = value.get("content")
        if isinstance(content, list) and content and isinstance(content[0], dict) and isinstance(content[0].get("text"), str):
            value = json.loads(content[0]["text"])
    if not isinstance(value, dict):
        fail(f"CLI JSON output was not an object: {value}")
    return value


def control_call(cli: str, args: Dict[str, Any], timeout: float = 10.0) -> Dict[str, Any]:
    payload = dict(args)
    payload["_rawJSON"] = True
    proc = subprocess.run(
        [cli, "--call", HIDDEN_TOOL, "--json", json.dumps(payload, separators=(",", ":")), "--compact"],
        text=True,
        capture_output=True,
        timeout=timeout,
    )
    if proc.returncode != 0:
        fail(f"control call failed rc={proc.returncode} stdout={proc.stdout[-500:]} stderr={proc.stderr[-500:]}")
    value = parse_cli_json(proc.stdout)
    if not value.get("ok"):
        fail(f"control call returned error: {value}")
    return value


def poll_connection_absent(cli: str, connection_id: str, timeout: float = 5.0) -> bool:
    deadline = time.monotonic() + timeout
    last: Optional[Dict[str, Any]] = None
    while time.monotonic() < deadline:
        last = control_call(cli, {"op": "connections", "include_identity": True}, timeout=10)
        ids = {entry.get("id") for entry in last.get("connections", []) if isinstance(entry, dict)}
        if connection_id not in ids:
            return True
        time.sleep(0.2)
    fail(f"connection {connection_id} still present after {timeout}s; last={last}")


def connection_entry(cli: str, connection_id: str) -> Optional[Dict[str, Any]]:
    snapshot = control_call(cli, {"op": "connections", "include_identity": True}, timeout=10)
    for entry in snapshot.get("connections", []):
        if isinstance(entry, dict) and entry.get("id") == connection_id:
            return entry
    return None


def wait_for_in_flight(cli: str, connection_id: str, timeout: float = 5.0) -> tuple[bool, Optional[Dict[str, Any]], Optional[Dict[str, Any]]]:
    deadline = time.monotonic() + timeout
    last_snapshot: Optional[Dict[str, Any]] = None
    last_entry: Optional[Dict[str, Any]] = None
    while time.monotonic() < deadline:
        last_snapshot = control_call(cli, {"op": "connections", "include_identity": True}, timeout=10)
        last_entry = None
        for entry in last_snapshot.get("connections", []):
            if isinstance(entry, dict) and entry.get("id") == connection_id:
                last_entry = entry
                break
        if last_entry and last_entry.get("has_in_flight_calls") is True:
            return True, last_entry, last_snapshot
        time.sleep(0.05)
    return False, last_entry, last_snapshot


def request_debug(request_id: str, args: Dict[str, Any]) -> Dict[str, Any]:
    return {
        "jsonrpc": "2.0",
        "id": request_id,
        "method": "tools/call",
        "params": {"name": HIDDEN_TOOL, "arguments": args},
    }


def scenario_pipeline(cli: str, args: argparse.Namespace) -> Dict[str, Any]:
    proxy = RawProxy(cli, args.timeout, verbose=args.verbose)
    try:
        proxy.initialize()
        proxy.send_obj(request_debug("p1", {"op": "ping", "tag": "p1"}))
        proxy.send_obj(request_debug("p2", {"op": "ping", "tag": "p2"}))
        proxy.send_obj(request_debug("p3", {"op": "ping", "tag": "p3"}))
        seen: Dict[str, Dict[str, Any]] = {}
        deadline = time.monotonic() + args.timeout
        while set(seen) != {"p1", "p2", "p3"} and time.monotonic() < deadline:
            response = proxy.read_response(timeout=max(0.1, deadline - time.monotonic()))
            rid = response.get("id")
            if rid in {"p1", "p2", "p3"}:
                payload = extract_debug_payload(response)
                if not payload.get("ok"):
                    fail(f"pipeline payload failed: {payload}")
                seen[rid] = payload
        if set(seen) != {"p1", "p2", "p3"}:
            fail(f"missing pipeline responses: {seen.keys()}")
        return {"responses": list(seen.keys())}
    finally:
        proxy.cleanup()


def scenario_batch(cli: str, args: argparse.Namespace) -> Dict[str, Any]:
    proxy = RawProxy(cli, args.timeout, verbose=args.verbose)
    try:
        proxy.initialize()
        proxy.send_obj([
            request_debug("b1", {"op": "ping", "tag": "b1"}),
            {"jsonrpc": "2.0", "method": "notifications/initialized"},
            {"jsonrpc": "2.0", "id": "b2", "method": "debug/does_not_exist", "params": {}},
            request_debug("b3", {"op": "sleep", "milliseconds": 50, "tag": "b3"}),
        ])
        batch = proxy.read_json()
        if not isinstance(batch, list):
            fail(f"batch response was not an array: {batch}")
        by_id = {item.get("id"): item for item in batch if isinstance(item, dict)}
        if set(by_id) != {"b1", "b2", "b3"}:
            fail(f"unexpected batch response IDs: {set(by_id)}")
        if extract_debug_payload(by_id["b1"]).get("ok") is not True:
            fail("b1 did not succeed")
        if extract_debug_payload(by_id["b3"]).get("ok") is not True:
            fail("b3 did not succeed")
        if by_id["b2"].get("error", {}).get("code") != -32601:
            fail(f"b2 should be method-not-found: {by_id['b2']}")
        proxy.send_line("[]")
        empty_response = proxy.read_json()
        if not isinstance(empty_response, dict) or empty_response.get("error", {}).get("code") != -32600:
            fail(f"empty batch should return invalid request: {empty_response}")
        return {"batch_ids": sorted(by_id.keys()), "empty_batch_code": -32600}
    finally:
        proxy.cleanup()


def scenario_parse_error(cli: str, args: argparse.Namespace) -> Dict[str, Any]:
    proxy = RawProxy(cli, args.timeout, verbose=args.verbose)
    try:
        proxy.initialize()
        proxy.send_line('{"jsonrpc":"2.0","id":"bad-parse","method":')
        response = proxy.read_json()
        if not isinstance(response, dict) or response.get("error", {}).get("code") != -32700:
            fail(f"parse error response had wrong shape: {response}")
        proxy.send_obj({"jsonrpc": "2.0", "id": "unknown-1", "method": "debug/does_not_exist", "params": {}})
        unknown = proxy.read_response("unknown-1")
        if unknown.get("error", {}).get("code") != -32601:
            fail(f"unknown method response had wrong shape: {unknown}")
        payload = proxy.call_debug({"op": "ping", "tag": "after-parse"}, request_id="after-parse")
        return {"parse_code": -32700, "unknown_code": -32601, "ping_ok": payload.get("ok")}
    finally:
        proxy.cleanup()


def scenario_notification(cli: str, args: argparse.Namespace) -> Dict[str, Any]:
    proxy = RawProxy(cli, args.timeout, verbose=args.verbose)
    try:
        proxy.initialize()
        proxy.send_obj({"jsonrpc": "2.0", "method": "notifications/initialized"})
        proxy.assert_no_stdout(timeout=0.3)
        payload = proxy.call_debug({"op": "ping", "tag": "after-notification"}, request_id="notif-ping")
        return {"notification_response": False, "ping_ok": payload.get("ok")}
    finally:
        proxy.cleanup()


def scenario_eof_cleanup(cli: str, args: argparse.Namespace) -> Dict[str, Any]:
    proxy = RawProxy(cli, args.timeout, verbose=args.verbose)
    try:
        proxy.initialize()
        connection_id = proxy.call_debug({"op": "ping", "tag": "eof-cleanup"}, request_id="target-ping")["connection_id"]
        proxy.close_stdin()
        rc = proxy.wait(timeout=args.timeout)
        poll_connection_absent(cli, connection_id, timeout=5)
        return {"connection_id": connection_id, "exit_code": rc}
    finally:
        proxy.cleanup()


def scenario_final_frame_close(cli: str, args: argparse.Namespace) -> Dict[str, Any]:
    proxy = RawProxy(cli, args.timeout, verbose=args.verbose)
    try:
        proxy.initialize()
        proxy.send_obj(request_debug("final-frame", {"op": "ping", "tag": "final-frame-close"}))
        proxy.close_stdin()
        response = proxy.read_response("final-frame", timeout=args.timeout)
        payload = extract_debug_payload(response)
        if payload.get("tag") != "final-frame-close":
            fail(f"final-frame-close tag mismatch: {payload}")
        rc = proxy.wait(timeout=args.timeout)
        poll_connection_absent(cli, payload["connection_id"], timeout=5)
        return {"connection_id": payload["connection_id"], "exit_code": rc, "response_id": response.get("id")}
    finally:
        proxy.cleanup()


def scenario_final_frame_close_delayed(cli: str, args: argparse.Namespace) -> Dict[str, Any]:
    proxy = RawProxy(cli, args.timeout, verbose=args.verbose)
    try:
        proxy.initialize()
        connection_id = proxy.call_debug({"op": "ping", "tag": "final-frame-close-delayed-target"}, request_id="target-ping")["connection_id"]
        proxy.send_obj(request_debug("final-frame-delayed", {"op": "sleep", "milliseconds": 200, "tag": "final-frame-close-delayed"}))
        proxy.close_stdin()
        response = proxy.read_response("final-frame-delayed", timeout=args.timeout)
        payload = extract_debug_payload(response)
        if payload.get("tag") != "final-frame-close-delayed" or payload.get("slept_milliseconds") != 200:
            fail(f"final-frame-close-delayed payload mismatch: {payload}")
        rc = proxy.wait(timeout=args.timeout)
        poll_connection_absent(cli, connection_id, timeout=5)
        return {"connection_id": connection_id, "exit_code": rc, "response_id": response.get("id")}
    finally:
        proxy.cleanup()


def scenario_kill_cleanup(cli: str, args: argparse.Namespace) -> Dict[str, Any]:
    proxy = RawProxy(cli, args.timeout, verbose=args.verbose)
    try:
        proxy.initialize()
        connection_id = proxy.call_debug({"op": "ping", "tag": "kill-cleanup"}, request_id="target-ping")["connection_id"]
        proxy.terminate()
        rc = proxy.wait(timeout=args.timeout)
        poll_connection_absent(cli, connection_id, timeout=5)
        return {"connection_id": connection_id, "exit_code": rc}
    finally:
        proxy.cleanup()


def scenario_stdout_broken_pipe(cli: str, args: argparse.Namespace) -> Dict[str, Any]:
    proxy = RawProxy(cli, args.timeout, verbose=args.verbose)
    try:
        proxy.initialize()
        connection_id = proxy.call_debug({"op": "ping", "tag": "stdout-broken-pipe"}, request_id="target-ping")["connection_id"]
        proxy.close_stdout_reader()
        proxy.send_obj(request_debug("large-broken-pipe", {"op": "large_response", "bytes": args.large_bytes or 1_048_576}))
        rc = proxy.wait(timeout=args.timeout)
        if rc < 0:
            fail(f"stdout broken pipe exited by signal rc={rc}; connection_id={connection_id}; stderr={proxy.stderr_text[-500:]}")
        if rc != 0:
            fail(f"stdout broken pipe expected exit 0, got {rc}; connection_id={connection_id}; stderr={proxy.stderr_text[-500:]}")
        poll_connection_absent(cli, connection_id, timeout=5)
        return {"connection_id": connection_id, "exit_code": rc, "stderr_tail": proxy.stderr_text[-300:]}
    finally:
        proxy.cleanup()


def scenario_stdout_stall(cli: str, args: argparse.Namespace) -> Dict[str, Any]:
    proxy = RawProxy(
        cli,
        args.timeout,
        env={"RP_STDOUT_STALL_TIMEOUT": "0.25", "RP_STDOUT_POLL_INTERVAL_MS": "10"},
        verbose=args.verbose,
    )
    try:
        proxy.initialize()
        connection_id = proxy.call_debug({"op": "ping", "tag": "stdout-stall"}, request_id="target-ping")["connection_id"]
        proxy.send_obj(request_debug("large-stall", {"op": "large_response", "bytes": args.large_bytes or 4_194_304}))
        # Deliberately stop reading stdout while keeping the pipe open.
        rc = proxy.wait(timeout=args.timeout)
        if rc != 73:
            fail(f"stdout stall expected exit 73, got {rc}; stderr={proxy.stderr_text[-500:]}")
        poll_connection_absent(cli, connection_id, timeout=5)
        return {"connection_id": connection_id, "exit_code": rc, "stderr_tail": proxy.stderr_text[-300:]}
    finally:
        proxy.cleanup()


def scenario_close_before_response(cli: str, args: argparse.Namespace) -> Dict[str, Any]:
    proxy = RawProxy(cli, args.timeout, verbose=args.verbose)
    try:
        proxy.initialize()
        connection_id = proxy.call_debug({"op": "ping", "tag": "close-before-response"}, request_id="target-ping")["connection_id"]
        proxy.send_obj(request_debug("sleep-large", {"op": "sleep_then_large_response", "milliseconds": 2_000, "bytes": 1_048_576}))
        saw_in_flight, in_flight_entry, latest_snapshot = wait_for_in_flight(cli, connection_id, timeout=5.0)
        if not saw_in_flight:
            fail(f"connection {connection_id} never reported has_in_flight_calls=true; latest_entry={in_flight_entry}; latest_snapshot={latest_snapshot}")
        proxy.terminate()
        rc = proxy.wait(timeout=args.timeout)
        poll_connection_absent(cli, connection_id, timeout=5)
        return {"connection_id": connection_id, "exit_code": rc, "saw_in_flight": saw_in_flight}
    finally:
        proxy.cleanup()


def cancellation_count(status: Dict[str, Any], marker: str) -> int:
    for entry in status.get("cancellations", []):
        if isinstance(entry, dict) and entry.get("marker") == marker:
            return int(entry.get("count", 0))
    return 0


def probe_status(cli: str, marker_a: str, marker_b: str) -> Dict[str, Any]:
    return control_call(cli, {"op": "active_tool_probe_status", "markers": [marker_a, marker_b]})


def assert_no_cancellation_for_stability(cli: str, marker_a: str, marker_b: str, duration: float = 0.75) -> Dict[str, Any]:
    deadline = time.monotonic() + duration
    last = probe_status(cli, marker_a, marker_b)
    while True:
        count_a = cancellation_count(last, marker_a)
        count_b = cancellation_count(last, marker_b)
        if count_a != 0 or count_b != 0:
            fail(f"unexpected cancellation during stability window: {last}")
        if time.monotonic() >= deadline:
            return last
        time.sleep(0.1)
        last = probe_status(cli, marker_a, marker_b)


def scenario_ownership(cli: str, args: argparse.Namespace) -> Dict[str, Any]:
    proxy_a = RawProxy(cli, args.timeout, verbose=args.verbose)
    proxy_b = RawProxy(cli, args.timeout, verbose=args.verbose)
    marker_a = "ownership-A"
    marker_b = "ownership-B"
    try:
        proxy_a.initialize()
        proxy_b.initialize()
        id_a = proxy_a.call_debug({"op": "ping", "tag": marker_a}, request_id="ping-a")["connection_id"]
        id_b = proxy_b.call_debug({"op": "ping", "tag": marker_b}, request_id="ping-b")["connection_id"]
        control_call(cli, {"op": "clear_active_tool_probe", "window_id": args.window_id, "markers": [marker_a, marker_b], "allow_destructive": True})
        control_call(cli, {"op": "seed_active_tool_probe", "window_id": args.window_id, "connection_id": id_a, "tool_name": "context_builder", "marker": marker_a, "allow_destructive": True})
        control_call(cli, {"op": "seed_active_tool_probe", "window_id": args.window_id, "connection_id": id_b, "tool_name": "context_builder", "marker": marker_b, "allow_destructive": True})
        control_call(cli, {"op": "force_remove_connection", "connection_id": id_a, "allow_destructive": True})
        status_after_a = assert_no_cancellation_for_stability(cli, marker_a, marker_b, duration=0.75)
        control_call(cli, {"op": "force_remove_connection", "connection_id": id_b, "allow_destructive": True})
        deadline = time.monotonic() + 5
        status_after_b = probe_status(cli, marker_a, marker_b)
        while cancellation_count(status_after_b, marker_b) < 1 and time.monotonic() < deadline:
            time.sleep(0.1)
            status_after_b = probe_status(cli, marker_a, marker_b)
        if cancellation_count(status_after_b, marker_b) < 1:
            fail(f"removing B should cancel B probe: {status_after_b}")
        return {"connection_a": id_a, "connection_b": id_b, "after_b": status_after_b}
    finally:
        try:
            control_call(cli, {"op": "clear_active_tool_probe", "window_id": args.window_id, "markers": [marker_a, marker_b], "allow_destructive": True})
        except Exception:
            pass
        proxy_a.cleanup()
        proxy_b.cleanup()


def assert_reconnect_invariants(before: Dict[str, Any], after: Dict[str, Any], pid_before: int, proxy: RawProxy) -> None:
    if proxy.pid != pid_before or proxy.proc.poll() is not None:
        fail(f"proxy process identity changed or exited: before={pid_before} after={proxy.pid} poll={proxy.proc.poll()}")
    if before.get("connection_id") == after.get("connection_id"):
        fail(f"app-side connection_id did not change across restart: {before.get('connection_id')}")
    if not before.get("session_fingerprint") or before.get("session_fingerprint") != after.get("session_fingerprint"):
        fail(f"session fingerprint changed across restart: before={before} after={after}")
    if before.get("client_name") != after.get("client_name"):
        fail(f"client name changed across restart: before={before.get('client_name')} after={after.get('client_name')}")


def restart_ack_via_proxy(proxy: RawProxy, delay_ms: int, down_ms: int, request_id: str) -> Dict[str, Any]:
    return proxy.call_debug({
        "op": "shutdown_and_restart",
        "allow_destructive": True,
        "mode": "network_manager",
        "delay_ms": delay_ms,
        "down_ms": down_ms,
    }, request_id=request_id, timeout=10)


def reinitialize_after_restart(proxy: RawProxy, client_name: str, delay_ms: int, down_ms: int, request_prefix: str, timeout: float) -> Dict[str, Any]:
    # Give the response-first restart time to tear down and recreate the app-side listener before
    # sending the explicit MCP initialize for the new app-side MCP.Server.
    time.sleep((delay_ms + down_ms) / 1000.0 + 0.5)
    proxy.initialize(client_name=client_name, request_id=f"{request_prefix}-init", timeout=timeout)
    return proxy.call_debug({"op": "ping", "tag": f"{request_prefix}-after"}, request_id=f"{request_prefix}-ping", timeout=timeout)


def assert_history_has_reboot_events(history: Dict[str, Any], restart_id: str, old_connection_id: str, new_connection_id: str) -> None:
    events = history.get("events", [])
    event_names = {entry.get("event") for entry in events if isinstance(entry, dict)}
    if "restart_scheduled" not in event_names or "restart_start_end" not in event_names:
        fail(f"history missing restart lifecycle events for {restart_id}: {events}")
    if not any(isinstance(entry, dict) and entry.get("connection_id") == old_connection_id and entry.get("event") in {"removed", "soft_disconnected", "terminated"} for entry in events):
        fail(f"history missing old connection removal for {old_connection_id}: {events}")
    if not any(isinstance(entry, dict) and entry.get("connection_id") == new_connection_id and entry.get("event") == "registered" for entry in events):
        fail(f"history missing new connection registration for {new_connection_id}: {events}")


def persisted_record_for(routing: Dict[str, Any], session_fingerprint: str, window_id: int) -> Optional[Dict[str, Any]]:
    for record in routing.get("persisted_records", []):
        if not isinstance(record, dict):
            continue
        if record.get("session_fingerprint") == session_fingerprint and record.get("last_window_id") == window_id:
            return record
    return None


def wait_for_persisted_record(proxy: RawProxy, session_fingerprint: str, window_id: int, request_prefix: str, timeout: float = 3.0) -> Dict[str, Any]:
    deadline = time.monotonic() + timeout
    last: Dict[str, Any] = {}
    attempt = 0
    while time.monotonic() < deadline:
        attempt += 1
        last = proxy.call_debug({"op": "routing_snapshot", "include_records": True, "include_windows": True}, request_id=f"{request_prefix}-routing-{attempt}")
        if persisted_record_for(last, session_fingerprint, window_id) is not None:
            return last
        time.sleep(0.1)
    fail(f"missing persisted routing record for session={session_fingerprint} window={window_id}: {last}")


def bind_context_window(list_payload: Dict[str, Any], window_id: int) -> Dict[str, Any]:
    for window in list_payload.get("windows", []):
        if isinstance(window, dict) and window.get("window_id") == window_id:
            return window
    fail(f"bind_context list did not include window_id={window_id}: {list_payload}")


def bind_context_workspace_name(window: Dict[str, Any]) -> Optional[str]:
    workspace = window.get("workspace")
    if isinstance(workspace, dict):
        name = workspace.get("name")
        if isinstance(name, str):
            return name
    return None


def bind_context_workspace_id(window: Dict[str, Any]) -> Optional[str]:
    workspace = window.get("workspace")
    if isinstance(workspace, dict):
        workspace_id = workspace.get("id")
        if isinstance(workspace_id, str):
            return workspace_id
    return None


def active_tab_summary(window: Dict[str, Any]) -> Optional[Dict[str, Any]]:
    active_context_id = window.get("active_context_id")
    for tab in window.get("tabs", []):
        if isinstance(tab, dict) and tab.get("context_id") == active_context_id:
            return tab
    for tab in window.get("tabs", []):
        if isinstance(tab, dict) and tab.get("is_active") is True:
            return tab
    return None


def reboot_basic_flow(cli: str, args: argparse.Namespace, *, down_ms: int = 1000, delay_ms: int = 250, client_name: str = "RepoPrompt CLI (Interactive)", prefix: str = "reboot") -> tuple[RawProxy, Dict[str, Any]]:
    proxy = RawProxy(cli, args.timeout, verbose=args.verbose)
    try:
        proxy.initialize(client_name=client_name)
        proxy.call_debug({"op": "clear_connection_history", "allow_destructive": True}, request_id=f"{prefix}-clear-history")
        pid_before = proxy.pid
        before = proxy.call_debug({"op": "ping", "tag": f"{prefix}-before"}, request_id=f"{prefix}-before")
        proxy.call_debug({"op": "connection_snapshot", "include_history": True}, request_id=f"{prefix}-snapshot-before")
        restart_started = time.monotonic()
        ack = restart_ack_via_proxy(proxy, delay_ms=delay_ms, down_ms=down_ms, request_id=f"{prefix}-restart")
        after = reinitialize_after_restart(proxy, client_name=client_name, delay_ms=delay_ms, down_ms=down_ms, request_prefix=prefix, timeout=args.timeout)
        reconnect_elapsed_ms = int((time.monotonic() - restart_started) * 1000)
        assert_reconnect_invariants(before, after, pid_before, proxy)
        history = proxy.call_debug({"op": "connection_history", "limit": 200}, request_id=f"{prefix}-history")
        assert_history_has_reboot_events(history, ack["restart_id"], before["connection_id"], after["connection_id"])
        details = {
            "proxy_pid": pid_before,
            "before_connection_id": before["connection_id"],
            "after_connection_id": after["connection_id"],
            "session_fingerprint": after.get("session_fingerprint"),
            "client_name": after.get("client_name"),
            "restart_id": ack.get("restart_id"),
            "down_ms": down_ms,
            "reconnect_elapsed_ms": reconnect_elapsed_ms,
        }
        return proxy, details
    except Exception:
        proxy.cleanup()
        raise


def scenario_reboot_basic(cli: str, args: argparse.Namespace) -> Dict[str, Any]:
    proxy, details = reboot_basic_flow(cli, args, prefix="reboot-basic")
    try:
        return details
    finally:
        proxy.cleanup()


def scenario_reboot_delay(cli: str, args: argparse.Namespace) -> Dict[str, Any]:
    down_ms = 3000
    proxy, details = reboot_basic_flow(cli, args, down_ms=down_ms, prefix="reboot-delay")
    try:
        if details["reconnect_elapsed_ms"] < max(0, down_ms - 500):
            fail(f"reconnect elapsed unexpectedly short for delay scenario: {details}")
        return details
    finally:
        proxy.cleanup()


def scenario_reboot_with_binding(cli: str, args: argparse.Namespace) -> Dict[str, Any]:
    proxy = RawProxy(cli, args.timeout, verbose=args.verbose)
    delay_ms = 250
    down_ms = 1000
    client_name = "RepoPrompt CLI (Interactive)"
    try:
        proxy.initialize(client_name=client_name)
        proxy.call_debug({"op": "clear_connection_history", "allow_destructive": True}, request_id="binding-clear-history")
        pid_before = proxy.pid
        before = proxy.call_debug({"op": "ping", "tag": "binding-before"}, request_id="binding-before")

        # Seed through the public routing API so the scenario validates the normal client path.
        list_before = proxy.call_bind_context({"op": "list", "window_id": args.window_id}, request_id="binding-list-before")
        window_before = bind_context_window(list_before, args.window_id)
        workspace_before = bind_context_workspace_name(window_before)
        workspace_id_before = bind_context_workspace_id(window_before)
        active_context_id_before = window_before.get("active_context_id")
        active_tab_before = active_tab_summary(window_before)
        active_context_name_before = active_tab_before.get("name") if isinstance(active_tab_before, dict) else None
        if workspace_before is None or "BombSquad" not in workspace_before:
            fail(f"window {args.window_id} is not showing the BombSquad workspace: {list_before}")

        if isinstance(active_context_id_before, str) and active_context_id_before:
            bind_args = {"op": "bind", "window_id": args.window_id, "context_id": active_context_id_before}
            bind_mode = "context"
        else:
            bind_args = {"op": "bind", "window_id": args.window_id}
            bind_mode = "window"
        bind_result = proxy.call_bind_context(bind_args, request_id="binding-bind")

        before_routing = wait_for_persisted_record(proxy, before["session_fingerprint"], args.window_id, request_prefix="binding-before")
        binding_before = before_routing.get("binding", {}) if isinstance(before_routing.get("binding"), dict) else {}
        if binding_before.get("window_id") != args.window_id:
            fail(f"binding did not target window {args.window_id}: {before_routing}")
        restart_started = time.monotonic()
        ack = restart_ack_via_proxy(proxy, delay_ms=delay_ms, down_ms=down_ms, request_id="binding-restart")
        after = reinitialize_after_restart(proxy, client_name=client_name, delay_ms=delay_ms, down_ms=down_ms, request_prefix="binding", timeout=args.timeout)
        reconnect_elapsed_ms = int((time.monotonic() - restart_started) * 1000)
        assert_reconnect_invariants(before, after, pid_before, proxy)

        # Public status/list after reconnect exercises the same routing fallback a real host would use.
        status_after = proxy.call_bind_context({"op": "status"}, request_id="binding-status-after")
        list_after = proxy.call_bind_context({"op": "list", "window_id": args.window_id}, request_id="binding-list-after")
        window_after = bind_context_window(list_after, args.window_id)
        workspace_after = bind_context_workspace_name(window_after)
        workspace_id_after = bind_context_workspace_id(window_after)
        active_context_id_after = window_after.get("active_context_id")
        active_tab_after = active_tab_summary(window_after)
        active_context_name_after = active_tab_after.get("name") if isinstance(active_tab_after, dict) else None

        after_routing = wait_for_persisted_record(proxy, after["session_fingerprint"], args.window_id, request_prefix="binding-after")
        binding_after = after_routing.get("binding", {}) if isinstance(after_routing.get("binding"), dict) else {}
        status_binding_after = status_after.get("binding", {}) if isinstance(status_after.get("binding"), dict) else {}
        restored_window_id = binding_after.get("window_id") or status_binding_after.get("window_id")
        if restored_window_id != args.window_id:
            fail(f"routing did not restore window {args.window_id}: routing={after_routing} status={status_after}")
        if workspace_id_before and workspace_id_after and workspace_id_before != workspace_id_after:
            fail(f"routing restored a different workspace: before={list_before} after={list_after}")
        if workspace_after is None or "BombSquad" not in workspace_after:
            fail(f"routing restored unexpected workspace: routing={after_routing} list_after={list_after}")
        if isinstance(active_context_id_before, str) and active_context_id_before and active_context_id_after != active_context_id_before:
            fail(
                "active context changed across reconnect: "
                f"before_active_context_id={active_context_id_before} "
                f"after_active_context_id={active_context_id_after} "
                f"before_list={list_before} after_list={list_after} "
                f"status_after={status_after} routing_after={after_routing}"
            )
        history = proxy.call_debug({"op": "connection_history", "limit": 200}, request_id="binding-history")
        assert_history_has_reboot_events(history, ack["restart_id"], before["connection_id"], after["connection_id"])
        return {
            "proxy_pid": pid_before,
            "before_connection_id": before["connection_id"],
            "after_connection_id": after["connection_id"],
            "session_fingerprint": after.get("session_fingerprint"),
            "client_name": after.get("client_name"),
            "restart_id": ack.get("restart_id"),
            "reconnect_elapsed_ms": reconnect_elapsed_ms,
            "bind_mode": bind_mode,
            "before_binding_kind": binding_before.get("binding_kind"),
            "after_binding_kind": binding_after.get("binding_kind") or status_binding_after.get("binding_kind"),
            "before_workspace": workspace_before,
            "after_workspace": workspace_after,
            "before_workspace_id": workspace_id_before,
            "after_workspace_id": workspace_id_after,
            "before_active_context_id": active_context_id_before,
            "after_active_context_id": active_context_id_after,
            "before_active_context_name": active_context_name_before,
            "after_active_context_name": active_context_name_after,
            "explicit_context_binding_restored": bool(binding_after.get("explicit") or status_binding_after.get("explicit")),
            "bind_result": bind_result,
            "status_after": status_after,
        }
    finally:
        proxy.cleanup()


def scenario_reboot_with_inflight(cli: str, args: argparse.Namespace) -> Dict[str, Any]:
    proxy = RawProxy(cli, args.timeout, verbose=args.verbose)
    delay_ms = 100
    down_ms = 1000
    client_name = "RepoPrompt CLI (Interactive)"
    try:
        proxy.initialize(client_name=client_name)
        pid_before = proxy.pid
        before = proxy.call_debug({"op": "ping", "tag": "inflight-before"}, request_id="inflight-before")
        proxy.send_obj(request_debug("inflight-sleep", {"op": "sleep_then_large_response", "milliseconds": 2000, "bytes": 1024}))
        saw_in_flight, in_flight_entry, latest_snapshot = wait_for_in_flight(cli, before["connection_id"], timeout=5.0)
        if not saw_in_flight:
            fail(f"connection never reported in-flight before restart: entry={in_flight_entry} snapshot={latest_snapshot}")
        restart_started = time.monotonic()
        ack = control_call(cli, {"op": "shutdown_and_restart", "allow_destructive": True, "mode": "network_manager", "delay_ms": delay_ms, "down_ms": down_ms}, timeout=10)
        inflight_response = proxy.try_read_response("inflight-sleep", timeout=0.5)
        after = reinitialize_after_restart(proxy, client_name=client_name, delay_ms=delay_ms, down_ms=down_ms, request_prefix="inflight", timeout=args.timeout)
        reconnect_elapsed_ms = int((time.monotonic() - restart_started) * 1000)
        assert_reconnect_invariants(before, after, pid_before, proxy)
        return {
            "proxy_pid": pid_before,
            "before_connection_id": before["connection_id"],
            "after_connection_id": after["connection_id"],
            "session_fingerprint": after.get("session_fingerprint"),
            "restart_id": ack.get("restart_id"),
            "reconnect_elapsed_ms": reconnect_elapsed_ms,
            "saw_in_flight": saw_in_flight,
            "inflight_response_observed": inflight_response is not None,
        }
    finally:
        proxy.cleanup()


def scenario_multi_client_reboot(cli: str, args: argparse.Namespace) -> Dict[str, Any]:
    proxy_a = RawProxy(cli, args.timeout, verbose=args.verbose)
    proxy_b = RawProxy(cli, args.timeout, verbose=args.verbose)
    delay_ms = 250
    down_ms = 1000
    try:
        proxy_a.initialize(client_name="RepoPrompt CLI (Interactive A)")
        proxy_b.initialize(client_name="RepoPrompt CLI (Interactive B)")
        before_a = proxy_a.call_debug({"op": "ping", "tag": "multi-a-before"}, request_id="multi-a-before")
        before_b = proxy_b.call_debug({"op": "ping", "tag": "multi-b-before"}, request_id="multi-b-before")
        if before_a.get("session_fingerprint") == before_b.get("session_fingerprint"):
            fail(f"multi-client sessions should be distinct: a={before_a} b={before_b}")
        pid_a = proxy_a.pid
        pid_b = proxy_b.pid
        ack = restart_ack_via_proxy(proxy_a, delay_ms=delay_ms, down_ms=down_ms, request_id="multi-restart")
        after_a = reinitialize_after_restart(proxy_a, client_name="RepoPrompt CLI (Interactive A)", delay_ms=delay_ms, down_ms=down_ms, request_prefix="multi-a", timeout=args.timeout)
        after_b = reinitialize_after_restart(proxy_b, client_name="RepoPrompt CLI (Interactive B)", delay_ms=0, down_ms=0, request_prefix="multi-b", timeout=args.timeout)
        assert_reconnect_invariants(before_a, after_a, pid_a, proxy_a)
        assert_reconnect_invariants(before_b, after_b, pid_b, proxy_b)
        if after_a.get("session_fingerprint") == after_b.get("session_fingerprint"):
            fail(f"multi-client sessions crossed over: a={after_a} b={after_b}")
        return {
            "restart_id": ack.get("restart_id"),
            "proxy_a_pid": pid_a,
            "proxy_b_pid": pid_b,
            "before_a_connection_id": before_a.get("connection_id"),
            "after_a_connection_id": after_a.get("connection_id"),
            "before_b_connection_id": before_b.get("connection_id"),
            "after_b_connection_id": after_b.get("connection_id"),
            "session_a": after_a.get("session_fingerprint"),
            "session_b": after_b.get("session_fingerprint"),
        }
    finally:
        proxy_a.cleanup()
        proxy_b.cleanup()


def scenario_reboot_host_semantics(cli: str, args: argparse.Namespace) -> Dict[str, Any]:
    proxy = RawProxy(cli, args.timeout, verbose=args.verbose)
    delay_ms = 250
    down_ms = 1000
    try:
        proxy.initialize()
        before = proxy.call_debug({"op": "ping", "tag": "host-before"}, request_id="host-before")
        ack = restart_ack_via_proxy(proxy, delay_ms=delay_ms, down_ms=down_ms, request_id="host-restart")
        time.sleep((delay_ms + down_ms) / 1000.0 + 0.75)
        transparent = False
        after: Optional[Dict[str, Any]] = None
        error: Optional[str] = None
        try:
            after = proxy.call_debug({"op": "ping", "tag": "host-after-no-reinit"}, request_id="host-after", timeout=3)
            transparent = bool(after.get("ok")) and after.get("connection_id") != before.get("connection_id") and after.get("session_fingerprint") == before.get("session_fingerprint")
        except Exception as exc:
            error = str(exc)
        if os.environ.get("EXPECT_TRANSPARENT_RECONNECT") == "1" and not transparent:
            fail(f"transparent reconnect without reinitialize failed: after={after} error={error}")
        return {
            "restart_id": ack.get("restart_id"),
            "before_connection_id": before.get("connection_id"),
            "after_connection_id": (after or {}).get("connection_id"),
            "session_fingerprint": before.get("session_fingerprint"),
            "transparent_without_reinitialize": transparent,
            "diagnostic_error": error,
        }
    finally:
        proxy.cleanup()


SCENARIOS = {
    "pipeline": scenario_pipeline,
    "batch": scenario_batch,
    "parse-error": scenario_parse_error,
    "notification": scenario_notification,
    "eof-cleanup": scenario_eof_cleanup,
    "final-frame-close": scenario_final_frame_close,
    "final-frame-close-delayed": scenario_final_frame_close_delayed,
    "kill-cleanup": scenario_kill_cleanup,
    "stdout-broken-pipe": scenario_stdout_broken_pipe,
    "stdout-stall": scenario_stdout_stall,
    "close-before-response": scenario_close_before_response,
    "ownership": scenario_ownership,
    "reboot-basic": scenario_reboot_basic,
    "reboot-with-binding": scenario_reboot_with_binding,
    "reboot-delay": scenario_reboot_delay,
    "reboot-with-inflight": scenario_reboot_with_inflight,
    "multi-client-reboot": scenario_multi_client_reboot,
    "reboot-host-semantics": scenario_reboot_host_semantics,
}


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = argparse.ArgumentParser(description="RepoPrompt raw proxy debug diagnostics driver")
    parser.add_argument("--cli", required=True, help="Path to rp-cli-debug/repoprompt-mcp")
    parser.add_argument("--scenario", required=True, choices=sorted(SCENARIOS.keys()))
    parser.add_argument("--timeout", type=float, default=10.0)
    parser.add_argument("--window-id", type=int, default=1)
    parser.add_argument("--large-bytes", type=int, default=0)
    parser.add_argument("--verbose", action="store_true")
    args = parser.parse_args(argv)

    try:
        details = SCENARIOS[args.scenario](args.cli, args)
        print(json.dumps({"ok": True, "scenario": args.scenario, "details": details}, sort_keys=True))
        return 0
    except Exception as exc:
        print(json.dumps({"ok": False, "scenario": args.scenario, "error": str(exc)}, sort_keys=True))
        if args.verbose:
            raise
        return 1


if __name__ == "__main__":
    sys.exit(main())
