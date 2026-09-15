"""Strict Verilog-2001 compilation and self-checking Stage 1 simulations.

Usage: py -3 -B scripts/run_stage1.py [--quick]
--quick skips only the exhaustive matcher run. No network access is performed.
IVERILOG and VVP may be set to existing executables; otherwise PATH and then the
project-local .tools/iverilog/mingw64/bin toolchain are searched.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
BUILD = ROOT / "build" / "stage1"


def tool(name):
    explicit = os.environ.get(name.upper())
    found = explicit or shutil.which(name)
    if found:
        return str(Path(found).resolve())
    cached = ROOT / ".tools" / "iverilog" / "mingw64" / "bin" / (name + ".exe")
    if cached.exists():
        return str(cached)
    raise RuntimeError(f"Missing {name}; install Icarus or explicitly run scripts/setup_iverilog.py")


def execute(command, env, log, timeout=180):
    started = time.monotonic()
    result = subprocess.run(command, cwd=ROOT, env=env, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=timeout)
    log.write_text(result.stdout, encoding="utf-8")
    return result, round(time.monotonic() - started, 3)


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
        raise RuntimeError("Icarus toolchain incomplete; see build/stage1/tool_version.log")
    print(version.stdout.splitlines()[0], flush=True)
    cases = [("tb_wfq_reset_sync", {}), ("tb_wfq_trie_upper_regs", {})]
    cases += [("tb_wfq_sync_ram", {"DATA_WIDTH": width}) for width in (10, 11, 16, 37)]
    legal = [(4, 16), (5, 16), (10, 1024), (11, 1024), (11, 2048), (12, 4096), (16, 65536)]
    cases += [("tb_wfq_init_ctrl", {"PTR_WIDTH": ptr, "MEM_DEPTH": depth}) for ptr, depth in legal]
    if not args.quick:
        cases.append(("tb_wfq_matcher16", {}))
    summary = {"language": "Verilog-2001 (-g2001)", "quick": args.quick,
               "tool": version.stdout.splitlines()[0], "tests": [], "negative_elaboration": []}
    sources = sorted((ROOT / "rtl").rglob("*.v")) + sorted((ROOT / "rtl").rglob("*.vh"))
    sources += sorted((ROOT / "tb").glob("*.v"))
    sources += [ROOT / "rtl/files.f", Path(__file__).resolve(), ROOT / "scripts/check_rtl_style.py"]
    summary["source_sha256"] = {str(path.relative_to(ROOT)).replace("\\", "/"):
                                hashlib.sha256(path.read_bytes()).hexdigest() for path in sources}

    def compile_tb(top, params, label):
        output = BUILD / (label + ".vvp")
        command = [iverilog, "-g2001", "-Wall", "-I", "rtl/include", "-s", top]
        command += [f"-P{top}.{key}={value}" for key, value in params.items()]
        command += ["-o", str(output), "-c", "rtl/files.f", f"tb/{top}.v"]
        result, elapsed = execute(command, env, BUILD / (label + ".compile.log"))
        return result, elapsed, output

    for top, params in cases:
        label = top + "".join(f"_{key.lower()}{value}" for key, value in params.items())
        compiled, _, output = compile_tb(top, params, label)
        if compiled.returncode or re.search(r"\bwarning\b", compiled.stdout, re.I):
            raise RuntimeError(label + " compile failed/warned:\n" + compiled.stdout)
        result, elapsed = execute([vvp, "-N", str(output)], env, BUILD / (label + ".run.log"), 240)
        # $finish is Verilog-2001. Require an explicit PASS and reject any FAIL;
        # do not rely on simulator exit status alone.
        if result.returncode or "FAIL" in result.stdout or "PASS " + top not in result.stdout:
            raise RuntimeError(label + " simulation failed:\n" + result.stdout)
        message = next(line for line in result.stdout.splitlines() if line.startswith("PASS " + top))
        print(f"{message} ({elapsed:.3f}s)", flush=True)
        summary["tests"].append({"name": label, "parameters": params, "seconds": elapsed,
                                 "result": message})

    illegal = [(3, 16), (4, 32), (9, 1024), (10, 2048), (10, 1000),
               (10, 8), (17, 1024), (16, 131072)]
    for ptr, depth in illegal:
        label = f"invalid_ptr{ptr}_depth{depth}"
        result, _, _ = compile_tb("tb_wfq_init_ctrl", {"PTR_WIDTH": ptr, "MEM_DEPTH": depth}, label)
        if result.returncode == 0 or "wfq_error_invalid_node_capacity_or_pointer_width" not in result.stdout:
            raise RuntimeError(label + " was not rejected by the parameter guard:\n" + result.stdout)
        summary["negative_elaboration"].append({"PTR_WIDTH": ptr, "MEM_DEPTH": depth, "rejected": True})
    print(f"PASS negative elaboration: {len(illegal)} invalid PTR_WIDTH/MEM_DEPTH pairs", flush=True)
    summary["status"] = "PASS"
    (BUILD / "results.json").write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")
    print(f"PASS Stage 1: {len(cases)} simulations; logs in {BUILD}")


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, subprocess.SubprocessError) as error:
        if BUILD.exists():
            (BUILD / "results.json").write_text(json.dumps({"status": "FAIL", "error": str(error)}) + "\n",
                                               encoding="utf-8")
        print("FAIL: " + str(error), file=sys.stderr)
        sys.exit(1)
