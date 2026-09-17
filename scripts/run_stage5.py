"""FAST5 functional acceptance only; never runs synthesis or STA.

Default: directed/parameter/bounded/fault suites, 10 seeds x 100,000 accepted
random operations for each of 10/1024 and 11/1024, and full stages 1-3.
Use --suite long --accepted 10000 --seeds 12345 for development only.
--resume reuses individually completed simulations only when the exact RTL/TB,
parameters, plusargs and simulator version match. Results are revalidated.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor, as_completed
import csv
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time

from run_stage1 import tool, execute

ROOT = Path(__file__).resolve().parents[1]
BUILD = ROOT / "build" / "stage5"
TOP = "tb_wfq_engine_acceptance"
SEEDS = [12345, 5381, 67891, 104729, 130363, 169087, 224737, 275015, 350377, 479909]


def digest(paths):
    return {p.relative_to(ROOT).as_posix(): hashlib.sha256(p.read_bytes()).hexdigest() for p in paths}


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8")


def parse_output(output, top):
    if "FAIL" in output:
        raise RuntimeError("Simulation reported FAIL:\n" + output[-6000:])
    lines = [line for line in output.splitlines() if line.startswith("PASS " + top + " ")]
    if len(lines) != 1:
        raise RuntimeError("Expected exactly one PASS: " + top)
    metrics = {k: int(v) for k, v in re.findall(r"\b(\w+)=(\d+)(?=\s|$)", lines[0])}
    return lines[0], metrics


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--suite", choices=["all", "directed", "long", "parameters", "bounded", "faults", "components"], default="all")
    parser.add_argument("--jobs", type=int, default=4)
    parser.add_argument("--accepted", type=int, default=100000)
    parser.add_argument("--seeds", type=int, nargs="+", default=SEEDS)
    parser.add_argument("--resume", action="store_true")
    args = parser.parse_args()
    if args.jobs < 1 or args.accepted < 1 or len(set(args.seeds)) != len(args.seeds):
        parser.error("jobs/accepted must be positive and seeds distinct")
    BUILD.mkdir(parents=True, exist_ok=True)
    result_path = BUILD / ("results.json" if args.suite == "all" else f"results_{args.suite}.json")
    summary = {"status": "RUNNING", "suite": args.suite, "issue_interval": 5,
               "language": "Verilog-2001 (-g2001)", "synthesis_sta": "not executed",
               "random_accepted_target": args.accepted, "seeds": args.seeds,
               "tests": [], "negative_elaboration": [], "components": []}
    write_json(result_path, summary)
    try:
        subprocess.run([sys.executable, "-B", "scripts/check_rtl_style.py"], cwd=ROOT, check=True)
        iverilog, vvp = tool("iverilog"), tool("vvp")
        env = dict(os.environ)
        env["PATH"] = str(Path(iverilog).parent) + os.pathsep + str(Path(vvp).parent) + os.pathsep + env.get("PATH", "")
        version, _ = execute([iverilog, "-V"], env, BUILD / "tool_version.log", 30)
        if version.returncode or "Unable to" in version.stdout:
            raise RuntimeError("Incomplete Icarus installation")
        summary["tool"] = version.stdout.splitlines()[0]
        print(summary["tool"], flush=True)
        rtl = sorted((ROOT / "rtl").rglob("*.v")) + sorted((ROOT / "rtl").rglob("*.vh")) + [ROOT / "rtl/files.f"]
        sources = rtl + sorted((ROOT / "tb").glob("*.v")) + sorted((ROOT / "scripts").glob("run_stage*.py")) + [ROOT / "scripts/check_rtl_style.py"]
        summary["source_sha256"] = digest(sources)
        cases = []

        def add(group, ptr, depth, flow=9, mode=0, seed=None):
            params = {"PTR_WIDTH": ptr, "MEM_DEPTH": depth, "FLOW_ID_WIDTH": flow, "RUN_MODE": mode}
            top = TOP
            if group == "faults":
                top = "tb_wfq_engine_faults"
                params = {"PTR_WIDTH": ptr, "MEM_DEPTH": depth}
            plusargs = [] if seed is None else [f"+SEED={seed}", f"+TARGET={args.accepted}"]
            name = f"{group}_ptr{ptr}_depth{depth}_flow{flow}"
            if seed is not None:
                name += f"_seed{seed}_accepted{args.accepted}"
            cases.append({"name": name, "group": group, "top": top, "parameters": params, "plusargs": plusargs})

        if args.suite in ("all", "directed"):
            for ptr, depth, flow in [(4, 16, 8), (5, 16, 9), (5, 32, 12), (10, 1024, 9), (11, 1024, 12)]:
                add("directed", ptr, depth, flow)
        if args.suite in ("all", "long"):
            for ptr, flow in [(10, 9), (11, 12)]:
                for seed in args.seeds:
                    add("long", ptr, 1024, flow, 1, seed)
        if args.suite in ("all", "parameters"):
            for ptr, depth, flow in [(4, 16, 8), (5, 16, 9), (5, 32, 12), (10, 1024, 9), (11, 1024, 12),
                                     (11, 2048, 8), (12, 4096, 9), (16, 65536, 12)]:
                add("parameters", ptr, depth, flow, 2)
        if args.suite in ("all", "bounded"):
            for ptr, depth in [(4, 16), (5, 32)]:
                add("bounded", ptr, depth, 9, 3)
        if args.suite in ("all", "faults"):
            for ptr in (10, 11):
                add("faults", ptr, 1024)

        compiled = {}
        for case in cases:
            key = json.dumps([case["top"], case["parameters"]], sort_keys=True)
            if key not in compiled:
                label = case["top"] + "".join(f"_{k.lower()}{v}" for k, v in case["parameters"].items())
                output = BUILD / (label + ".vvp")
                command = [iverilog, "-g2001", "-Wall", "-I", "rtl/include", "-s", case["top"]]
                command += [f"-P{case['top']}.{k}={v}" for k, v in case["parameters"].items()]
                command += ["-o", str(output), "-c", "rtl/files.f", f"tb/{case['top']}.v"]
                result, _ = execute(command, env, BUILD / (label + ".compile.log"), 180)
                if result.returncode or re.search(r"\bwarning\b", result.stdout, re.I):
                    raise RuntimeError(label + " compile failed/warned:\n" + result.stdout)
                compiled[key] = output
            case["binary"] = str(compiled[key])
            case["simulation_inputs"] = {"tool": summary["tool"], "parameters": case["parameters"],
                                         "plusargs": case["plusargs"], "sources": digest(rtl + [ROOT / f"tb/{case['top']}.v"])}

        def run_case(case):
            label = case["name"]
            log = BUILD / (label + ".run.log")
            stamp = BUILD / (label + ".result.json")
            cached = None
            if args.resume and stamp.exists() and log.exists():
                candidate = json.loads(stamp.read_text(encoding="utf-8"))
                if candidate.get("status") == "PASS" and candidate.get("simulation_inputs") == case["simulation_inputs"]:
                    if candidate.get("log_sha256") == hashlib.sha256(log.read_bytes()).hexdigest():
                        cached = candidate
            if cached is None:
                print("RUN " + label, flush=True)
                started = time.monotonic()
                with log.open("w", encoding="utf-8") as stream:
                    result = subprocess.run([vvp, "-N", case["binary"]] + case["plusargs"], cwd=ROOT,
                                            env=env, stdout=stream, stderr=subprocess.STDOUT, timeout=2400)
                if result.returncode:
                    raise RuntimeError(label + " exited " + str(result.returncode))
                elapsed = round(time.monotonic() - started, 3)
            else:
                elapsed = cached["seconds"]
            output = log.read_text(encoding="utf-8")
            message, metrics = parse_output(output, case["top"])
            for parameter, field in [("PTR_WIDTH", "ptr"), ("MEM_DEPTH", "depth"),
                                     ("FLOW_ID_WIDTH", "flow"), ("RUN_MODE", "mode")]:
                if parameter in case["parameters"] and metrics.get(field) != case["parameters"][parameter]:
                    raise RuntimeError(label + " reported a different " + parameter)
            if case["group"] == "long":
                expected_seed = int(next(arg.split("=", 1)[1] for arg in case["plusargs"] if arg.startswith("+SEED=")))
                if metrics.get("seed") != expected_seed:
                    raise RuntimeError(label + " did not use the requested random seed")
            if case["group"] == "long" and metrics.get("random_accepts", 0) < args.accepted:
                raise RuntimeError(label + " did not reach accepted-operation target")
            if case["group"] == "directed" and metrics.get("sequences") != 28:
                raise RuntimeError(label + " missed directed operation patterns")
            if case["group"] == "bounded" and metrics.get("bounded") != 256:
                raise RuntimeError(label + " missed bounded traces")
            record = {k: v for k, v in case.items() if k != "binary"}
            record.update(status="PASS", result=message, metrics=metrics, seconds=elapsed,
                          reused=cached is not None, log_sha256=hashlib.sha256(log.read_bytes()).hexdigest())
            write_json(stamp, record)
            return record

        # Separate simulations run concurrently; shared RTL is read-only.
        with ThreadPoolExecutor(max_workers=args.jobs) as pool:
            futures = {pool.submit(run_case, case): case for case in cases}
            for future in as_completed(futures):
                record = future.result()
                summary["tests"].append(record)
                write_json(result_path, summary)
                print(record["result"] + (" [reused]" if record["reused"] else f" ({record['seconds']:.3f}s)"), flush=True)

        if args.suite in ("all", "parameters"):
            invalid = [({"ISSUE_INTERVAL": i}, "wfq_error_stage4_requires_issue_interval_5") for i in (4, 6)]
            invalid += [({"PTR_WIDTH": p, "MEM_DEPTH": d}, "wfq_error_invalid_node_capacity_or_pointer_width")
                        for p, d in [(9, 1024), (10, 1000), (11, 1000), (11, 4096), (10, 2048),
                                     (3, 16), (17, 1024), (10, 8), (16, 131072)]]
            invalid += [({"FLOW_ID_WIDTH": f}, "wfq_error_flow_id_width_must_be_8_to_12") for f in (7, 13)]
            invalid += [({p: v}, "wfq_error_fixed_tag_literal_epoch_widths") for p, v in
                        [("TAG_WIDTH", 11), ("EPOCH_WIDTH", 15), ("LITERAL_WIDTH", 3)]]
            for idx, (params, diagnostic) in enumerate(invalid):
                command = [iverilog, "-g2001", "-Wall", "-I", "rtl/include", "-s", TOP]
                command += [f"-P{TOP}.{k}={v}" for k, v in params.items()]
                command += ["-o", str(BUILD / f"invalid_{idx}.vvp"), "-c", "rtl/files.f", f"tb/{TOP}.v"]
                result, _ = execute(command, env, BUILD / f"invalid_{idx}.compile.log", 180)
                if not result.returncode or diagnostic not in result.stdout:
                    raise RuntimeError("Missing parameter rejection: " + str(params))
                summary["negative_elaboration"].append({"parameters": params, "rejected": True})

        if args.suite in ("all", "components"):
            for stage in (1, 2, 3):
                result, elapsed = execute([sys.executable, "-B", f"scripts/run_stage{stage}.py"], env,
                                          BUILD / f"stage{stage}_full.log", 1800)
                report = json.loads((ROOT / f"build/stage{stage}/results.json").read_text(encoding="utf-8"))
                if result.returncode or report.get("status") != "PASS" or report.get("quick"):
                    raise RuntimeError(f"Stage {stage} full regression failed:\n" + result.stdout[-6000:])
                summary["components"].append({"stage": stage, "seconds": elapsed, "report": report})
                write_json(result_path, summary)
                print(f"PASS component stage {stage}: {len(report['tests'])} simulations", flush=True)

        coverage = {}
        for case in summary["tests"]:
            if case["top"] != TOP:
                continue
            output = (BUILD / (case["name"] + ".run.log")).read_text(encoding="utf-8")
            config = f"{case['parameters']['PTR_WIDTH']}/{case['parameters']['MEM_DEPTH']}/{case['parameters']['FLOW_ID_WIDTH']}"
            for key, count in re.findall(r"^COVER (\d+) (\d+)$", output, re.M):
                key = int(key)
                coverage[(config, key)] = coverage.get((config, key), 0) + int(count)
        fields = [("insert", 0, 1), ("occupancy", 1, 3), ("duplicate", 3, 1), ("path", 4, 7),
                  ("bank_role", 7, 3), ("clear_level", 9, 3), ("position", 11, 3),
                  ("response_credit_used", 13, 3), ("previous_insert", 15, 3), ("next_raw", 17, 1)]
        cov_file = BUILD / ("coverage.csv" if args.suite == "all" else f"coverage_{args.suite}.csv")
        with cov_file.open("w", newline="", encoding="utf-8") as stream:
            writer = csv.writer(stream)
            writer.writerow(["configuration", "key"] + [f[0] for f in fields] + ["hits"])
            for (config, key), hits in sorted(coverage.items()):
                writer.writerow([config, key] + [(key >> shift) & mask for _, shift, mask in fields] + [hits])
        summary["coverage_joint_bins"] = len(coverage)
        summary["coverage_axes"] = {}
        expected_axes = [{0, 1}, {0, 1, 2}, {0, 1}, {0, 1, 2, 3, 4}, {0, 1, 2},
                         {0, 1, 2, 3}, {0, 1, 2, 3}, {0, 1, 2}, {0, 1, 2}, {0, 1}]
        for config in sorted({config for config, _ in coverage}):
            keys = [key for cfg, key in coverage if cfg == config]
            axes = {name: sorted({(key >> shift) & mask for key in keys}) for name, shift, mask in fields}
            summary["coverage_axes"][config] = axes
            if args.suite in ("all", "directed") and config in ("10/1024/9", "11/1024/12"):
                for (name, _, _), expected in zip(fields, expected_axes):
                    if set(axes[name]) != expected:
                        raise RuntimeError(f"Missing required coverage bins: {config} {name}: {axes[name]}")
        summary["source_sha256_at_end"] = digest(sources)
        if summary["source_sha256"] != summary["source_sha256_at_end"]:
            raise RuntimeError("Sources changed during the regression; results cannot qualify acceptance")
        summary["random_scale_met"] = (args.suite == "all" and args.accepted >= 100000 and len(args.seeds) >= 10)
        summary["status"] = "PASS"
        summary["exclusions"] = ["PIPE6 and F25 comparison are not implemented", "F30 synthesis/STA deferred by user",
                                 "Bounded enumeration is simulation, not solver-based formal proof"]
        write_json(result_path, summary)
        print(f"PASS Stage 5 {args.suite}: {len(cases)} simulations; {len(summary['negative_elaboration'])} rejected configurations; "
              f"random_scale_met={summary['random_scale_met']}", flush=True)
    except Exception as error:
        summary["status"] = "FAIL"
        summary["error"] = str(error)
        write_json(result_path, summary)
        raise


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, OSError, subprocess.SubprocessError) as error:
        print("FAIL:", error, file=sys.stderr)
        sys.exit(1)
