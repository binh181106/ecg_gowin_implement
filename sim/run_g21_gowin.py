"""Build G2.1 in an isolated project after both RTL regressions PASS.

Original impl/, project state and source are never build outputs.
The copied ecg_board.sdc constrains sys_clk to 20 ns (50 MHz).
global_freq=100 preserves G1's synthesis optimization option; STA uses the SDC.
"""
import hashlib
import json
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]
RESULTS = ROOT / "sim/g21_results"
BUILD = RESULTS / "gowin_build"
TOOL = Path("C:/Gowin/Gowin_V1.9.12.01_x64/IDE/bin/gw_sh.exe")


def main():
    for name, expected in [("g1_after", 12), ("signed", 8)]:
        summary = (RESULTS/name/"summary.txt").read_text()
        assert ": FAIL" not in summary and summary.count(": PASS") == expected, name
        assert "protected inputs unchanged: True" in summary, name
    if BUILD.exists():
        raise RuntimeError("Build checkpoint exists; preserve it and use a new output directory")
    assert TOOL.is_file(), TOOL
    BUILD.mkdir(parents=True)
    shutil.copytree(ROOT/"src", BUILD/"src", ignore=shutil.ignore_patterns("__pycache__"))
    shutil.copy2(ROOT/"Bao_rom.gprj", BUILD/"Bao_rom.gprj")
    sources = [p for p in (BUILD/"src").rglob("*") if p.is_file()]
    (BUILD/"input_sha256.json").write_text(json.dumps({p.relative_to(BUILD).as_posix():
        hashlib.sha256(p.read_bytes()).hexdigest() for p in sources}, indent=2)+"\n")
    tcl = """open_project {Bao_rom.gprj}
set_option -top_module top_ecg_acg525_board
set_option -verilog_std sysv2017
set_option -global_freq 100
set_option -print_all_synthesis_warning 1
saveto -all_options effective_options.tcl
run all
"""
    (BUILD/"build.tcl").write_text(tcl, encoding="ascii")
    print(f"Gowin isolated build: {BUILD}", flush=True)
    with (RESULTS/"gowin_console.log").open("w", encoding="utf-8") as log:
        result = subprocess.run([str(TOOL), "build.tcl"], cwd=BUILD, stdout=log,
                                stderr=subprocess.STDOUT, timeout=1800)
    (RESULTS/"gowin_exit.txt").write_text(f"exit_code={result.returncode}\n")
    print(f"Gowin exit={result.returncode}; inspect synthesis/P&R/STA reports", flush=True)
    return result.returncode


if __name__ == "__main__":
    raise SystemExit(main())
