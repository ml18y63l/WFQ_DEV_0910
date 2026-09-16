"""Stage 5 "long" suite cocotb driver: 2 configurations x 10 seeds.

Port-level equivalent of `py -3 scripts/run_stage5.py --suite long`: configs
(PTR_WIDTH, MEM_DEPTH, FLOW_ID_WIDTH) = (10,1024,9) and (11,1024,12), the ten
default seeds from run_stage5.py, each run reaching --target accepted random
operations (default 100000).

Run from any directory inside an activated RTL environment (iverilog, make and
cocotb-config on PATH; Git Bash uses the conda `python`, CMD uses `py -3`):
    python verification/cocotb/run_long.py [--quick] [--jobs N] [--target N]
                                           [--config 10|11|all] [--seeds S ...]

--quick uses target 5000. Each run gets its own SIM_BUILD and a log file under
verification/cocotb/build/; a machine-readable summary is written to
build/results_long.json.
"""

import argparse
import json
import os
import re
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

HERE = Path(__file__).resolve().parent
BUILD = HERE / "build"
SEEDS = [12345, 5381, 67891, 104729, 130363, 169087, 224737, 275015, 350377, 479909]
CONFIGS = {"10": (10, 1024, 9), "11": (11, 1024, 12)}


def run_one(ptr, depth, flow, seed, target):
    name = f"long_ptr{ptr}_depth{depth}_flow{flow}_seed{seed}_accepted{target}"
    # Relative POSIX path: make/shell choke on absolute Windows paths with backslashes.
    sim_build = f"build/sim_build/{name}"
    log_path = BUILD / f"{name}.log"
    command = ["make", f"SIM_BUILD={sim_build}", f"PTR_WIDTH={ptr}", f"MEM_DEPTH={depth}",
               f"FLOW_ID_WIDTH={flow}", f"SEED={seed}", f"TARGET={target}"]
    started = time.monotonic()
    proc = subprocess.run(command, cwd=HERE, text=True, stdout=subprocess.PIPE,
                          stderr=subprocess.STDOUT)
    seconds = round(time.monotonic() - started, 1)
    log_path.write_text(proc.stdout, encoding="utf-8", errors="replace")
    summary = re.search(r"PASS cocotb_long_random .*", proc.stdout)
    passed = proc.returncode == 0 and summary is not None and "TESTS=1 PASS=1 FAIL=0" in proc.stdout
    line = summary.group(0) if summary else "no PASS summary"
    print(f"{'PASS' if passed else 'FAIL'} {name} ({seconds}s): {line}", flush=True)
    return {"name": name, "passed": passed, "seconds": seconds, "summary": line,
            "parameters": {"PTR_WIDTH": ptr, "MEM_DEPTH": depth, "FLOW_ID_WIDTH": flow,
                           "SEED": seed, "TARGET": target}}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--quick", action="store_true", help="target 5000 accepted ops")
    parser.add_argument("--target", type=int, default=None, help="accepted ops per run")
    parser.add_argument("--jobs", type=int, default=1, help="parallel simulations")
    parser.add_argument("--config", choices=["10", "11", "all"], default="all")
    parser.add_argument("--seeds", type=int, nargs="+", default=SEEDS)
    args = parser.parse_args()
    if args.jobs < 1:
        parser.error("--jobs must be positive")
    target = args.target or (5000 if args.quick else 100000)
    BUILD.mkdir(parents=True, exist_ok=True)
    configs = list(CONFIGS.values()) if args.config == "all" else [CONFIGS[args.config]]
    runs = [(ptr, depth, flow, seed, target)
            for ptr, depth, flow in configs for seed in args.seeds]
    summary = {"status": "RUNNING", "suite": "long", "target": target, "runs": []}
    results_path = BUILD / "results_long.json"
    results_path.write_text(json.dumps(summary, indent=2), encoding="utf-8")
    started = time.monotonic()
    with ThreadPoolExecutor(max_workers=args.jobs) as pool:
        futures = [pool.submit(run_one, *run) for run in runs]
        results = [future.result() for future in futures]
    passed = sum(1 for r in results if r["passed"])
    summary["status"] = "PASS" if passed == len(results) else "FAIL"
    summary["seconds"] = round(time.monotonic() - started, 1)
    summary["runs"] = results
    results_path.write_text(json.dumps(summary, indent=2), encoding="utf-8")
    print(f"{summary['status']} cocotb long suite: {passed}/{len(results)} simulations "
          f"target={target}; logs and results_long.json in {BUILD}", flush=True)
    return 0 if passed == len(results) else 1


if __name__ == "__main__":
    sys.exit(main())
