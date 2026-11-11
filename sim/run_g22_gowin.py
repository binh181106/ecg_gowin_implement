"""Isolated Gowin G2.2 build, gated on complete current-source regression PASS.

python -I sim/run_g22_gowin.py [--out sim/g22_results/gowin_another_run]
Never overwrites an existing build or original impl/. STA uses copied 20ns SDC;
global_freq=100 preserves the G2.1 synthesis optimization option.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess

ROOT=Path(__file__).resolve().parents[1]
RESULTS=ROOT/"sim/g22_results"
TOOL=Path("C:/Gowin/Gowin_V1.9.12.01_x64/IDE/bin/gw_sh.exe")


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out",type=Path,default=RESULTS/"gowin_build")
    args=parser.parse_args(); build=args.out.resolve(); build.relative_to(RESULTS)
    summary=(RESULTS/"final/summary.txt").read_text()
    assert summary.count(": PASS")==21 and ": FAIL" not in summary
    assert "protected inputs unchanged: True" in summary
    for name,sha in json.loads((RESULTS/"final/input_sha256.json").read_text()).items():
        assert hashlib.sha256((ROOT/name).read_bytes()).hexdigest()==sha,"Tested input changed: "+name
    if build.exists(): raise RuntimeError("Preserve existing build; specify a fresh --out directory")
    assert TOOL.is_file(),TOOL
    build.mkdir(parents=True)
    shutil.copytree(ROOT/"src",build/"src",ignore=shutil.ignore_patterns("__pycache__"))
    shutil.copy2(ROOT/"Bao_rom.gprj",build/"Bao_rom.gprj")
    sha={p.relative_to(build).as_posix():hashlib.sha256(p.read_bytes()).hexdigest()
         for p in (build/"src").rglob("*") if p.is_file()}
    (build/"input_sha256.json").write_text(json.dumps(sha,indent=2)+"\n")
    (build/"build.tcl").write_text("""open_project {Bao_rom.gprj}
set_option -top_module top_ecg_acg525_board
set_option -verilog_std sysv2017
set_option -global_freq 100
set_option -print_all_synthesis_warning 1
saveto -all_options effective_options.tcl
run all
""")
    print("Building actual verified G2.2 RTL in "+str(build),flush=True)
    with (build/"console.log").open("w",encoding="utf-8") as log:
        result=subprocess.run([str(TOOL),"build.tcl"],cwd=build,stdout=log,
                              stderr=subprocess.STDOUT,timeout=1800)
    (build/"exit.txt").write_text(f"exit_code={result.returncode}\n")
    print("Gowin exit="+str(result.returncode)+"; inspect generated STA/resource reports",flush=True)
    return result.returncode


if __name__=="__main__":
    raise SystemExit(main())
