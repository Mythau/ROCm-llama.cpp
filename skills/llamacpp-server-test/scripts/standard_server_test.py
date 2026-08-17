#!/usr/bin/env python3
"""Plan and run the standard ROCm YOLO synchronized server test."""

from __future__ import annotations

import argparse
from contextlib import contextmanager
import importlib.util
import json
import os
import re
import subprocess
import sys
import threading
import time
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path


SCRIPT = Path(__file__).resolve()
SKILL_DIR = SCRIPT.parent.parent
REPO = SKILL_DIR.parent.parent
RUNTIME = REPO.parent.parent
HARNESS = RUNTIME / "concurrency-sync-bench.py"
AGGREGATES = REPO / "benchmarks/rocm-yolo/raw/aggregates.json"
DEFAULT_MODEL = Path(r"C:\AI\models\Qwen3.6-35B-A3B-Q8_0-mtp.gguf")
DEFAULT_SERVER = RUNTIME / "build/llamacpp-yolo-dynamic-spec-rocm714-gfx1100-gfx1201-hipgraphs-off/bin/llama-server.exe"
DEFAULT_CONTROL = RUNTIME / "build/llamacpp-yolo-allpatches-rocm714-gfx1100-gfx1201-hipgraphs-off/bin/llama-server.exe"
DEFAULT_OUTPUT = RUNTIME / "server-test-results"


SPEC_TO_HARNESS = {
    "none": "none",
    "ngram-mod": "ngram",
    "mtp": "mtp",
    "mtp+ngram-mod": "mtp-ngram",
}


def emit(message: str = ""):
    print(message, flush=True)


@contextmanager
def visible_stage(label: str, interval_seconds: float):
    started = time.perf_counter()
    stopped = threading.Event()

    def report_progress():
        while not stopped.wait(interval_seconds):
            elapsed = time.perf_counter() - started
            emit(f"[progress] {label}: running ({elapsed:.0f}s elapsed)")

    emit(f"[progress] {label}: started")
    reporter = threading.Thread(target=report_progress, daemon=True)
    reporter.start()
    try:
        yield
    except BaseException:
        elapsed = time.perf_counter() - started
        emit(f"[progress] {label}: failed after {elapsed:.1f}s")
        raise
    else:
        elapsed = time.perf_counter() - started
        emit(f"[progress] {label}: completed in {elapsed:.1f}s")
    finally:
        stopped.set()
        reporter.join()


def emit_wave_result(args, label: str, wave: dict):
    hard = "PASS" if wave["all_requests_pass"] else "FAIL"
    warning_count = int(wave.get("model_behavior_warning_count", 0))
    speculation = effective_spec(args.spec, args.spec_active_limit, args.active_requests)
    emit(
        f"[result] {label} {wave['wave_kind']} {wave['wave'] + 1}: "
        f"speculation {speculation} | "
        f"prefill {wave['aggregate_prompt_tps']:.2f} t/s | "
        f"decode {wave['aggregate_decode_tps']:.2f} t/s | "
        f"prompt {args.prompt_tokens} x {args.active_requests} | "
        f"decode {args.predict_tokens} x {args.active_requests} | "
        f"batch/microbatch {args.batch_size}/{args.ubatch_size} | "
        f"integrity {hard} | warnings {warning_count}"
    )


@dataclass(frozen=True)
class Historical:
    name: str
    spec: str
    batch: int | None
    ubatch: int | None
    active: int
    parallel: int
    prompt: int
    predict: int
    kv: str
    prefill: float
    decode: float


def load_harness():
    spec = importlib.util.spec_from_file_location("rocm_yolo_sync_bench", HARNESS)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot import benchmark harness: {HARNESS}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def ps_command(parts: list[str | Path]) -> str:
    return subprocess.list2cmdline([str(part) for part in parts])


def protocol_counts(args) -> tuple[int, int]:
    if args.mode == "quick":
        return 1, 1
    if args.mode == "final":
        return 1, 3
    return args.poc_warmups, args.poc_runs


def effective_spec(spec: str, limits: str | None, active: int) -> str:
    if not limits or spec == "none":
        return spec
    enabled = set(spec.split("+"))
    names = {"draft-mtp": "mtp", "ngram-mod": "ngram-mod"}
    for item in limits.split(","):
        name, value = item.split("=", 1)
        impl = names.get(name.strip())
        if impl and active > int(value):
            enabled.discard(impl)
    if not enabled:
        return "none"
    return "+".join(name for name in ("mtp", "ngram-mod") if name in enabled)


def historical_records() -> list[Historical]:
    data = json.loads(AGGREGATES.read_text(encoding="utf-8"))
    records: list[Historical] = []
    for row in data["synchronized_b2048_u512"]:
        records.append(Historical(
            name=f"ROCm YOLO synchronized {row['slots']}-request {row['speculation']}",
            spec=row["speculation"], batch=2048, ubatch=512,
            active=row["slots"], parallel=row["slots"], prompt=8192, predict=4096,
            kv="partitioned", prefill=float(row["aggregate_prefill"]), decode=float(row["active_decode"]),
        ))
    for row in data["four_slot_b8192_u1024"]:
        records.append(Historical(
            name=f"ROCm YOLO four-request {row['speculation']} b8192/u1024",
            spec=row["speculation"], batch=8192, ubatch=1024,
            active=4, parallel=4, prompt=8192, predict=4096,
            kv="partitioned", prefill=float(row["aggregate_prefill_mean"]), decode=float(row["active_decode_mean"]),
        ))
    for row in data["single_stream_8k_8k"]:
        records.append(Historical(
            name=f"ROCm YOLO single-stream {row['speculation']}",
            spec=row["speculation"], batch=None, ubatch=None,
            active=1, parallel=1, prompt=8192, predict=8192,
            kv="partitioned", prefill=float(row["prefill"]), decode=float(row["decode"]),
        ))
    return records


def choose_historical(args, comparison_spec: str) -> tuple[Historical, str, bool]:
    def score(row: Historical):
        spec_mismatch = row.spec != comparison_spec
        batch_mismatch = row.batch != args.batch_size or row.ubatch != args.ubatch_size
        return (
            spec_mismatch,
            batch_mismatch,
            abs(row.active - args.active_requests) + abs(row.parallel - args.server_parallel),
            abs(row.prompt - args.prompt_tokens) + abs(row.predict - args.predict_tokens),
            row.kv != args.kv,
        )

    row = min(historical_records(), key=score)
    exact = (
        row.spec == comparison_spec
        and row.batch == args.batch_size
        and row.ubatch == args.ubatch_size
        and row.active == args.active_requests
        and row.parallel == args.server_parallel
        and row.prompt == args.prompt_tokens
        and row.predict == args.predict_tokens
        and row.kv == args.kv
    )
    qualities = []
    qualities.append("same speculation set" if row.spec == comparison_spec else "different speculation set")
    qualities.append("same batch/microbatch" if row.batch == args.batch_size and row.ubatch == args.ubatch_size else "different batch/microbatch")
    qualities.append("same request/server shape" if row.active == args.active_requests and row.parallel == args.server_parallel else "different request/server shape")
    qualities.append("same token sizes" if row.prompt == args.prompt_tokens and row.predict == args.predict_tokens else "different token sizes")
    return row, "; ".join(qualities), exact


def build_server_command(bench, args, server: Path, spec: str, active_limit: str | None, port: int) -> list[str]:
    bench.MODEL = args.model
    return bench.server_args(
        port=port,
        n_parallel=args.server_parallel,
        unified=args.kv == "unified",
        spec=SPEC_TO_HARNESS[spec],
        cont_batching=True,
        n_ctx=args.ctx_size,
        spec_active_limit=active_limit,
        server_path=server,
        batch_size=args.batch_size,
        ubatch_size=args.ubatch_size,
    )


def print_plan(args, bench, current_command: list[str], control_command: list[str], historical: Historical, quality: str, exact: bool):
    warmups, measured = protocol_counts(args)
    run_argv = [sys.executable, str(SCRIPT)] + ["--action", "run"]
    skip = False
    for value in sys.argv[1:]:
        if skip:
            skip = False
            continue
        if value == "--action":
            skip = True
            continue
        if value.startswith("--action="):
            continue
        run_argv.append(value)
    emit(f"Claim: {args.purpose}")
    emit(f"Protocol: {args.mode}; {warmups} warmup; {measured} measured; {args.active_requests} simultaneous request(s) on {args.server_parallel} slot(s)")
    emit("Server invocation:")
    emit(ps_command(current_command))
    emit("Request/test invocation:")
    emit(ps_command(run_argv))
    emit(f"Historical comparison selected: {historical.name}")
    emit(f"Why this comparison is closest: {quality}; {'exact historical match' if exact else 'directional match'}")
    emit("Pre-dynamic live control invocation if required:")
    emit(ps_command(control_command))


def obvious_soup(text: str) -> bool:
    if not text.strip():
        return True
    if re.search(r"([^\s])\1{127,}", text):
        return True
    tokens = re.findall(r"\S+", text)
    if len(tokens) < 64:
        return False
    longest = 1
    run = 1
    for left, right in zip(tokens, tokens[1:]):
        run = run + 1 if left == right else 1
        longest = max(longest, run)
    return longest >= 24 or len(set(tokens)) / len(tokens) < 0.02


def ensure_idle_host():
    check = subprocess.run(
        ["powershell.exe", "-NoProfile", "-Command", "@(Get-Process -Name llama-server,llama-cli -ErrorAction SilentlyContinue).Count"],
        capture_output=True, text=True, check=True,
    )
    if int(check.stdout.strip() or "0"):
        raise RuntimeError("llama-server or llama-cli is already running; do not interrupt it")


def run_binary(bench, args, label: str, server: Path, spec: str, active_limit: str | None, port: int, root: Path) -> dict:
    ensure_idle_host()
    warmups, measured_count = protocol_counts(args)
    identity = bench.server_build_identity(server)
    test_dir = root / f"{label}-srv{identity[:12]}"
    test_dir.mkdir(parents=True, exist_ok=True)
    stdout_path = test_dir / "server.stdout.log"
    stderr_path = test_dir / "server.stderr.log"
    command = build_server_command(bench, args, server, spec, active_limit, port)
    metadata = {
        "label": label, "purpose": args.purpose, "mode": args.mode,
        "server": str(server), "server_sha256": identity, "command": command,
        "model": str(args.model), "spec": spec, "spec_active_limit": active_limit,
        "active_requests": args.active_requests, "server_parallel": args.server_parallel,
        "ctx_size": args.ctx_size, "prompt_tokens": args.prompt_tokens,
        "predict_tokens": args.predict_tokens, "batch_size": args.batch_size,
        "ubatch_size": args.ubatch_size, "kv": args.kv, "workload": args.workload,
        "warmups": warmups, "measured_runs": measured_count,
    }
    (test_dir / "command.json").write_text(json.dumps(metadata, indent=2), encoding="utf-8")
    emit(f"[progress] {label}: artifacts {test_dir}")
    emit(f"[progress] {label}: server SHA-256 {identity[:12]}; launching on port {port}")
    env = os.environ.copy()
    env["ROCBLAS_USE_HIPBLASLT"] = "0"
    env["LUCE_Q8_MEMO"] = "1"
    process = None
    waves = []
    try:
        with stdout_path.open("wb") as stdout_file, stderr_path.open("wb") as stderr_file:
            process = subprocess.Popen(
                command, cwd=server.parent, env=env,
                stdout=stdout_file, stderr=stderr_file,
                creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
            )
            with visible_stage(f"{label} server startup", args.progress_interval):
                bench.wait_ready(process, port, 600, stderr_path)
            emit(f"[progress] {label}: server ready")
            for index in range(warmups):
                wave_dir = test_dir / f"warmup-{index + 1:02d}"
                with visible_stage(f"{label} warmup {index + 1}/{warmups}", args.progress_interval):
                    wave = bench.run_wave(
                        port, label, args.active_requests, index, "warmup",
                        args.workload == "shared", wave_dir,
                        args.prompt_tokens, args.predict_tokens,
                    )
                waves.append(wave)
                emit_wave_result(args, label, wave)
            for index in range(measured_count):
                wave_dir = test_dir / f"measured-{index + 1:02d}"
                with visible_stage(f"{label} measured {index + 1}/{measured_count}", args.progress_interval):
                    wave = bench.run_wave(
                        port, label, args.active_requests, index, "measured",
                        args.workload == "shared", wave_dir,
                        args.prompt_tokens, args.predict_tokens,
                    )
                waves.append(wave)
                emit_wave_result(args, label, wave)
    finally:
        if process is not None and process.poll() is None:
            process.kill()
            try:
                process.wait(timeout=30)
            except subprocess.TimeoutExpired:
                pass
        time.sleep(3)
    validation = bench.validate_server_log(
        stderr_path, args.server_parallel, args.kv == "unified",
        args.prompt_tokens + args.predict_tokens,
        args.batch_size, args.ubatch_size,
        2 if "mtp" in spec else 1,
    )
    measured = [wave for wave in waves if wave["wave_kind"] == "measured"]
    soup = False
    for measured_dir in sorted(test_dir.glob("measured-*")):
        for output_path in measured_dir.glob("slot-*.txt"):
            soup = soup or obvious_soup(output_path.read_text(encoding="utf-8", errors="replace"))
    hard = validation["pass"] and all(wave["all_requests_pass"] for wave in measured) and not soup
    warning_count = sum(int(wave.get("model_behavior_warning_count", 0)) for wave in measured)
    coherence = "FAIL" if not hard else ("PASS (warnings)" if warning_count else "PASS")
    result = {
        **metadata,
        "server_validation": validation,
        "waves": waves,
        "measured_statistics": bench.measurement_statistics(measured),
        "coherence": coherence,
        "obvious_token_soup": soup,
        "warning_count": warning_count,
        "all_pass": hard,
    }
    (test_dir / "summary.json").write_text(json.dumps(result, indent=2), encoding="utf-8")
    emit(
        f"[result] {label} complete: coherence {coherence} | "
        f"server validation {'PASS' if validation['pass'] else 'FAIL'} | "
        f"summary {test_dir / 'summary.json'}"
    )
    return result


def headline(result: dict, key: str) -> float:
    stats = result["measured_statistics"][key]
    return float(stats["median"] if result["mode"] == "final" else stats["values"][-1])


def difference(current: float, baseline: float) -> float:
    return (current / baseline - 1.0) * 100.0


def report_markdown(args, current: dict, historical: Historical, quality: str, exact: bool, control: dict | None) -> str:
    current_pp = headline(current, "aggregate_prompt_tps")
    current_tg = headline(current, "aggregate_decode_tps")
    current_spec = effective_spec(args.spec, args.spec_active_limit, args.active_requests)
    rows = [{
        "name": "Current",
        "spec": current_spec,
        "pp": current_pp, "tg": current_tg,
        "prompt": args.prompt_tokens, "predict": args.predict_tokens,
        "active": args.active_requests,
        "batch": args.batch_size, "ubatch": args.ubatch_size,
        "coherence": current["coherence"],
    }, {
        "name": "Closest historical ROCm YOLO",
        "spec": historical.spec,
        "pp": historical.prefill, "tg": historical.decode,
        "prompt": historical.prompt, "predict": historical.predict,
        "active": historical.active,
        "batch": historical.batch, "ubatch": historical.ubatch,
        "coherence": "PASS (retained result)",
    }]
    if control:
        rows.append({
            "name": "Live pre-dynamic ROCm YOLO",
            "spec": current_spec,
            "pp": headline(control, "aggregate_prompt_tps"),
            "tg": headline(control, "aggregate_decode_tps"),
            "prompt": args.prompt_tokens, "predict": args.predict_tokens,
            "active": args.active_requests,
            "batch": args.batch_size, "ubatch": args.ubatch_size,
            "coherence": control["coherence"],
        })
    lines = [
        f"Claim: {args.purpose}",
        f"Protocol: {args.mode}; {protocol_counts(args)[0]} warmup; {protocol_counts(args)[1]} measured; {args.active_requests} request(s) on {args.server_parallel} slots.",
        "",
        "| Build/test | Speculation | Prefill t/s | Decode t/s | Prefill size | Decode size | Batch/microbatch | Coherence |",
        "|---|---|---:|---:|---:|---:|---:|---|",
    ]
    for row in rows:
        b = "unknown" if row["batch"] is None else f"{row['batch']}/{row['ubatch']}"
        lines.append(f"| {row['name']} | {row['spec']} | {row['pp']:.2f} | {row['tg']:.2f} | {row['prompt']} x {row['active']} | {row['predict']} | {b} | {row['coherence']} |")
    lines += [
        "",
        f"Historical difference: prefill {difference(current_pp, historical.prefill):+.2f}%; decode {difference(current_tg, historical.decode):+.2f}%.",
        f"Historical comparison quality: {'exact historical' if exact else 'directional'} ({quality}).",
    ]
    if control:
        control_pp = headline(control, "aggregate_prompt_tps")
        control_tg = headline(control, "aggregate_decode_tps")
        lines.append(f"Live-control difference: prefill {difference(current_pp, control_pp):+.2f}%; decode {difference(current_tg, control_tg):+.2f}%.")
    if args.mode == "final":
        pp_values = current["measured_statistics"]["aggregate_prompt_tps"]["values"]
        tg_values = current["measured_statistics"]["aggregate_decode_tps"]["values"]
        lines.append("Current measured prefill values: " + " / ".join(f"{value:.2f}" for value in pp_values))
        lines.append("Current measured decode values: " + " / ".join(f"{value:.2f}" for value in tg_values))
        if control:
            pp_values = control["measured_statistics"]["aggregate_prompt_tps"]["values"]
            tg_values = control["measured_statistics"]["aggregate_decode_tps"]["values"]
            lines.append("Control measured prefill values: " + " / ".join(f"{value:.2f}" for value in pp_values))
            lines.append("Control measured decode values: " + " / ".join(f"{value:.2f}" for value in tg_values))
    lines.append("Warnings: " + (str(current["warning_count"]) if current["warning_count"] else "none"))
    return "\n".join(lines) + "\n"


def parse_args():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--action", choices=("plan", "run"), default="plan")
    parser.add_argument("--mode", choices=("poc", "quick", "final"), required=True)
    parser.add_argument("--purpose", required=True)
    parser.add_argument("--server", type=Path, default=DEFAULT_SERVER)
    parser.add_argument("--control-server", type=Path, default=DEFAULT_CONTROL)
    parser.add_argument("--model", type=Path, default=DEFAULT_MODEL)
    parser.add_argument("--spec", choices=tuple(SPEC_TO_HARNESS), required=True)
    parser.add_argument("--spec-active-limit")
    parser.add_argument("--active-requests", type=int, required=True)
    parser.add_argument("--server-parallel", type=int, required=True)
    parser.add_argument("--ctx-size", type=int, default=0)
    parser.add_argument("--prompt-tokens", type=int, required=True)
    parser.add_argument("--predict-tokens", type=int, required=True)
    parser.add_argument("--batch-size", type=int, required=True)
    parser.add_argument("--ubatch-size", type=int, required=True)
    parser.add_argument("--kv", choices=("partitioned", "unified"), default="partitioned")
    parser.add_argument("--workload", choices=("disjoint", "shared"), default="disjoint")
    parser.add_argument("--poc-warmups", type=int, default=0)
    parser.add_argument("--poc-runs", type=int, default=1)
    parser.add_argument("--port", type=int, default=18250)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--progress-interval", type=float, default=15.0, help="seconds between progress lines during startup and waves")
    parser.add_argument("--no-auto-control", action="store_true")
    args = parser.parse_args()
    if args.ctx_size == 0:
        args.ctx_size = args.server_parallel * (args.prompt_tokens + args.predict_tokens + 256)
    if args.active_requests > args.server_parallel:
        parser.error("active requests cannot exceed server parallel")
    if args.mode != "poc" and (args.poc_warmups != 0 or args.poc_runs != 1):
        parser.error("custom repetition counts are only valid for poc mode")
    if min(args.active_requests, args.server_parallel, args.ctx_size, args.prompt_tokens, args.predict_tokens, args.batch_size, args.ubatch_size) <= 0:
        parser.error("sizes and counts must be positive")
    if args.progress_interval <= 0:
        parser.error("progress interval must be positive")
    return args


def main() -> int:
    args = parse_args()
    bench = load_harness()
    comparison_spec = effective_spec(args.spec, args.spec_active_limit, args.active_requests)
    historical, quality, exact = choose_historical(args, comparison_spec)
    current_command = build_server_command(bench, args, args.server, args.spec, args.spec_active_limit, args.port)
    control_command = build_server_command(bench, args, args.control_server, comparison_spec, None, args.port + 1)
    print_plan(args, bench, current_command, control_command, historical, quality, exact)
    if args.action == "plan":
        return 0
    for path in (args.server, args.control_server, args.model):
        if not path.exists():
            raise FileNotFoundError(path)
    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    result_root = args.output / f"{stamp}-{args.mode}-{args.active_requests}req-{args.spec.replace('+', '-')}-b{args.batch_size}-u{args.ubatch_size}"
    current = run_binary(bench, args, "current", args.server, args.spec, args.spec_active_limit, args.port, result_root)
    current_pp = headline(current, "aggregate_prompt_tps")
    current_tg = headline(current, "aggregate_decode_tps")
    prefill_difference = difference(current_pp, historical.prefill)
    decode_difference = difference(current_tg, historical.decode)
    needs_control = (
        abs(prefill_difference) > 5.0
        or abs(decode_difference) > 10.0
        or current["coherence"].startswith("FAIL")
        or not exact
    )
    emit(
        f"[comparison] current vs historical: prefill {prefill_difference:+.2f}% | "
        f"decode {decode_difference:+.2f}% | coherence {current['coherence']}"
    )
    control = None
    if needs_control and not args.no_auto_control:
        emit("[comparison] threshold crossed: starting exact live pre-dynamic control")
        control = run_binary(bench, args, "pre-dynamic-control", args.control_server, comparison_spec, None, args.port + 1, result_root)
    elif needs_control:
        emit("[comparison] threshold crossed: live pre-dynamic control required but disabled")
    else:
        emit("[comparison] historical thresholds retained: live control not required")
    report = report_markdown(args, current, historical, quality, exact, control)
    (result_root / "report.md").write_text(report, encoding="utf-8")
    emit("\n" + report)
    emit(f"Artifacts: {result_root}")
    if needs_control and args.no_auto_control:
        emit("LIVE PRE-DYNAMIC CONTROL REQUIRED before an equivalence/regression conclusion")
    return 0 if current["all_pass"] and (control is None or control["all_pass"]) else 2


if __name__ == "__main__":
    raise SystemExit(main())
