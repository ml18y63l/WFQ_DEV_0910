"""Mechanical subset of RTL_Coding_Style.md; not a full HDL/style parser.

Checks whitespace, module/file naming, identifier alignment, declaration-only
wire/reg lines, basic Verilog-2001 exclusions and sequential register suffixes.
Reset topology, logic locality, inference and timing still need RTL review.
"""
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
DECL = re.compile(r"^(\s*(?:(?:input|output|inout)\s+)?(?:wire|reg|integer|genvar)\s*"
                  r"(?:signed\s*)?(?:\[[^\]]+\]\s*)?)([a-zA-Z_]\w*)")


def main():
    errors = []
    files = sorted((ROOT / "rtl").rglob("*.v")) + sorted((ROOT / "rtl").rglob("*.vh"))
    for path in files:
        source = path.read_text(encoding="utf-8")
        label = str(path.relative_to(ROOT))
        if not source.endswith("\n"):
            errors.append(f"{label}: missing EOF newline")
        clean = re.sub(r"/\*.*?\*/|//[^\n]*", "", source, flags=re.S)
        if path.suffix == ".v":
            modules = re.findall(r"\bmodule\s+(\w+)", clean)
            if modules != [path.stem]:
                errors.append(f"{label}: require one module matching filename")
            if not all(key in source.split("`timescale")[0] for key in
                       ("Project", "File", "Spec", "Function")):
                errors.append(f"{label}: missing header before timescale")
        if re.search(r"\b(?:logic|bit|always_ff|always_comb|always_latch|typedef|struct|"
                     r"interface|package|endpackage|enum)\b|\$clog2\b|(?<!\w)'[01xz]\b", clean):
            errors.append(f"{label}: forbidden SystemVerilog construct")
        columns = set()
        for number, line in enumerate(source.splitlines(), 1):
            at = f"{label}:{number}"
            if "\t" in line or line.rstrip() != line:
                errors.append(f"{at}: tabs or trailing whitespace")
            if (len(line) - len(line.lstrip())) % 4:
                errors.append(f"{at}: indentation not multiple of four")
            code = line.split("//", 1)[0]
            match = DECL.match(code)
            if match:
                name = match.group(2)
                columns.add(match.start(2) + 1)
                if not re.fullmatch(r"[a-z][a-z0-9_]*", name):
                    errors.append(f"{at}: signal must be lower snake_case")
                if "=" in code:
                    errors.append(f"{at}: declaration assignment")
                if "]" in match.group(1) and len(match.group(1).rsplit("]", 1)[1]) < 4:
                    errors.append(f"{at}: fewer than four spaces after width")
            connection = re.match(r"\s*\.\w+\s+(\()", code)
            if connection:
                columns.add(connection.start(1) + 1)
            if re.search(r"\bend\s+else\b", code):
                errors.append(f"{at}: else must be on a separate line")
            if re.search(r"\bend\b\s*[^\s]", code):
                errors.append(f"{at}: end must be alone")
            # LHS of nonblocking assignments in these RTL sources.
            lhs = re.match(r"\s*(\w+)(?:\[[^\]]*\])*\s*<=", code)
            if lhs and not re.search(r"_d(?:[1-9][0-9]*)?$", lhs.group(1)):
                errors.append(f"{at}: sequential register requires _d suffix")
        if columns and (len(columns) != 1 or min(columns) < 40):
            errors.append(f"{label}: signal/connection alignment columns {sorted(columns)}")
    if errors:
        print("\n".join(errors))
        return 1
    print(f"PASS RTL mechanical style checks: {len(files)} files")
    return 0


if __name__ == "__main__":
    sys.exit(main())
