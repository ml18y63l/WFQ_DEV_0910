#!/usr/bin/env bash
# Run with: bash verification/vcs_sim/run_vcs.sh
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "$script_dir/../.." && pwd)"
out_dir="${OUT_DIR:-$repo_root/build/vcs_sim/tag_wrap}"
vcs_bin="${VCS:-vcs}"

command -v "$vcs_bin" >/dev/null 2>&1 || { echo "ERROR: VCS executable not found: $vcs_bin" >&2; exit 1; }
# Most installations provide the legacy-compatible VCS FSDB PLI here.
# FSDB_PLI_DIR supports a site-specific Verdi/Novas installation layout.
pli_dir="${FSDB_PLI_DIR:-${VERDI_HOME:-${NOVAS_HOME:-}}/share/PLI/VCS/LINUX64}"
for name in novas.tab pli.a; do
    if [[ ! -r "$pli_dir/$name" ]]; then
        echo "ERROR: missing $pli_dir/$name; set VERDI_HOME or FSDB_PLI_DIR." >&2
        exit 1
    fi
done
mkdir -p -- "$out_dir"
out_dir="$(cd -- "$out_dir" && pwd)"
export LD_LIBRARY_PATH="$pli_dir${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

# files.f paths are relative to the repository root. Keep generated files in OUT_DIR.
cd -- "$repo_root"
"$vcs_bin" -full64 +v2k -timescale=1ns/1ps \
    -debug_access+all +define+FSDB +incdir+rtl/include \
    -P "$pli_dir/novas.tab" "$pli_dir/pli.a" \
    -f rtl/files.f "$script_dir/tb_wfq_tag_wrap.v" \
    -top tb_wfq_tag_wrap -Mdir="$out_dir/csrc" \
    -o "$out_dir/simv" -l "$out_dir/compile.log"

cd -- "$out_dir"
# Remove only the previous run's success evidence, never source files.
rm -f -- sim.log wfq_tag_wrap.fsdb
./simv +FSDB_FILE=wfq_tag_wrap.fsdb -l sim.log
if grep -q 'FAIL tb_wfq_tag_wrap' sim.log || \
   ! grep -q '^PASS tb_wfq_tag_wrap scenarios=2 inserts=18 extracts=18 responses=18 ' sim.log; then
    echo "ERROR: simulation did not pass; see $out_dir/sim.log" >&2
    exit 1
fi
if [[ ! -s wfq_tag_wrap.fsdb ]]; then
    echo "ERROR: simulation passed but FSDB output is missing or empty." >&2
    exit 1
fi
echo "PASS: $out_dir/wfq_tag_wrap.fsdb"
