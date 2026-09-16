"""FAST5 stage 3 resource-control Verilog-2001 regression.

Run from any directory: py -3 -B scripts/run_stage3.py [--quick]
The quick run reduces random resource traffic from 30000 to 2000 cycles per
configuration. Full capacity, FIFO and fault tests are unchanged. Uses the local
Icarus setup from run_stage1.py; never downloads tools.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys

from run_stage1 import tool, execute

ROOT = Path(__file__).resolve().parents[1]
BUILD = ROOT / "build" / "stage3"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--quick", action="store_true")
    args = parser.parse_args()
    BUILD.mkdir(parents=True, exist_ok=True)
    (BUILD / "results.json").write_text('{"status": "RUNNING"}\n', encoding="utf-8")
    subprocess.run([sys.executable, "-B", "scripts/check_rtl_style.py"], cwd=ROOT, check=True)
    iverilog, vvp = tool("iverilog"), tool("vvp")
    env = dict(os.environ)
    env["PATH"] = str(Path(iverilog).parent) + os.pathsep + str(Path(vvp).parent) + os.pathsep + env.get("PATH", "")
    version, _ = execute([iverilog, "-V"], env, BUILD / "tool_version.log", 30)
    if version.returncode or "Unable to" in version.stdout:
        raise RuntimeError("Incomplete Icarus installation")
    print(version.stdout.splitlines()[0], flush=True)
    cases = [("tb_wfq_admission_ctrl", {})]
    cases += [("tb_wfq_free_slot_stack", {"PTR_WIDTH": ptr, "MEM_DEPTH": depth})
             for ptr, depth in [(4,16), (10,1024), (11,1024), (16,65536)]]
    cases += [("tb_wfq_response_fifo", {"FLOW_ID_WIDTH": flow}) for flow in [8,9,12]]
    cases += [("tb_wfq_resource_ctrl", {"PTR_WIDTH": ptr, "MEM_DEPTH": depth,
                "FLOW_ID_WIDTH": flow, "SEED": seed,
                "RANDOM_CYCLES": 2000 if args.quick else 30000})
              for ptr, depth, flow, seed in [(4,16,8,12345), (10,1024,9,12345),
                                             (10,1024,9,5381), (11,1024,12,67891)]]
    cases += [("tb_wfq_resource_faults", {"PTR_WIDTH": ptr, "MEM_DEPTH": depth})
              for ptr, depth in [(10,1024),(5,16)]]
    summary = {"status": "RUNNING", "language": "Verilog-2001 (-g2001)",
               "issue_interval": 5, "quick": args.quick,
               "tool": version.stdout.splitlines()[0], "tests": [], "negative_elaboration": []}
    sources = sorted((ROOT / "rtl").rglob("*.v")) + sorted((ROOT / "rtl").rglob("*.vh"))
    sources += [ROOT / ("tb/" + top + ".v") for top in sorted({case[0] for case in cases})]
    sources += [ROOT / "rtl/files.f", Path(__file__).resolve(), ROOT / "scripts/run_stage1.py",
                ROOT / "scripts/check_rtl_style.py"]
    summary["source_sha256"] = {path.relative_to(ROOT).as_posix(): hashlib.sha256(path.read_bytes()).hexdigest()
                                for path in sources}

    def compile_case(top, params, label):
        output = BUILD / (label + ".vvp")
        command = [iverilog, "-g2001", "-Wall", "-I", "rtl/include", "-s", top]
        command += [f"-P{top}.{key}={value}" for key, value in params.items()]
        command += ["-o", str(output), "-c", "rtl/files.f", f"tb/{top}.v"]
        compiled, _ = execute(command, env, BUILD / (label + ".compile.log"))
        return compiled, output

    for top, params in cases:
        label = top + "".join(f"_{key.lower()}{value}" for key, value in params.items())
        compiled, output = compile_case(top, params, label)
        if compiled.returncode or re.search(r"\bwarning\b", compiled.stdout, re.I):
            raise RuntimeError(label + " compile failed/warned:\n" + compiled.stdout)
        result, elapsed = execute([vvp, "-N", str(output)], env, BUILD / (label + ".run.log"), 240)
        if result.returncode or "FAIL" in result.stdout or "PASS " + top not in result.stdout:
            raise RuntimeError(label + " simulation failed:\n" + result.stdout)
        message = next(line for line in result.stdout.splitlines() if line.startswith("PASS " + top))
        print(f"{message} ({elapsed:.3f}s)", flush=True)
        summary["tests"].append({"name": label, "parameters": params, "result": message, "seconds": elapsed})
        (BUILD / "results.json").write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")
    invalid = [
        ({"ISSUE_INTERVAL": 4}, "wfq_error_stage3_requires_issue_interval_5"),
        ({"ISSUE_INTERVAL": 6}, "wfq_error_stage3_requires_issue_interval_5"),
        ({"PTR_WIDTH": 9, "MEM_DEPTH": 1024}, "wfq_error_invalid_node_capacity_or_pointer_width"),
        ({"PTR_WIDTH": 10, "MEM_DEPTH": 1000}, "wfq_error_invalid_node_capacity_or_pointer_width"),
        ({"FLOW_ID_WIDTH": 7}, "wfq_error_flow_id_width_must_be_8_to_12"),
        ({"FLOW_ID_WIDTH": 13}, "wfq_error_flow_id_width_must_be_8_to_12"),
    ]
    for idx, (params, diagnostic) in enumerate(invalid):
        result, _ = compile_case("tb_wfq_resource_ctrl", params, f"invalid_{idx}")
        if result.returncode == 0 or diagnostic not in result.stdout:
            raise RuntimeError("Missing parameter rejection: " + str(params) + "\n" + result.stdout)
        summary["negative_elaboration"].append({"parameters": params, "rejected": True})
    summary["status"] = "PASS"
    (BUILD / "results.json").write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")
    print(f"PASS Stage 3 FAST5: {len(cases)} simulations; {len(invalid)} rejected configurations", flush=True)


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, subprocess.SubprocessError) as error:
        if BUILD.exists():
            (BUILD / "results.json").write_text(json.dumps({"status": "FAIL", "error": str(error)}) + "\n",
                                               encoding="utf-8")
        print("FAIL: " + str(error), file=sys.stderr)
        sys.exit(1)
