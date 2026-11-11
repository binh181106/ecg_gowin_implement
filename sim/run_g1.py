"""Reproducible Questa regression. No golden generation, synthesis or Git writes.

python -I sim/run_g1.py
python -I sim/run_g1.py --baseline  # expected failures against HEAD RTL
Use --tests NAME... to rerun selected tests. Artifacts: sim/g1_results/.
"""
import argparse
import hashlib
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "sim/g1_results"
RTL = ["control_fsm.v", "apb_slave_if.v", "demo_apb_seq.v", "top_ecg_rom_demo.v",
       "ai_classifier.v", "demo_uart_packetizer.v", "uart_tx.v", "ecg_rom.v",
       "sample_pacer.v", "adc_interface.v", "window_buffer.v", "feature_extraction.v",
       "gowin_sdpb/gowin_sdpb.v", "top_ecg_acg525_board.v"]
TESTS = {
    "control": ("tb_g1_control", "G1 CONTROL PASS", []),
    "start_accept": ("tb_g1_start_accept", "G1 START ACCEPT PASS", []),
    "apb": ("tb_g1_apb", "G1 APB PASS", []),
    "seq": ("tb_g1_seq", "G1 SEQ PASS", []),
    "class_uart": ("tb_g1_class_uart", "G1 CLASS UART PASS", []),
    "rom_uart": ("tb_g1_rom_uart", "G1 ROM UART PASS", []),
    "rom_uart_injected": ("tb_g1_rom_uart", "G1 ROM UART PASS", ["+INJECT_CLASS"]),
    "reset": ("tb_g1_reset", "G1 RESET PASS", []),
    "g2_rom": ("tb_g1_rom_golden", "G1/G2 CHECK PASS", []),
    "g2_checkpoint": ("tb_feature_checkpoint", "G2 CHECKPOINT PASS", []),
}
PROTECTED = [ROOT / "src" / p for p in
             ["feature_extraction.v", "window_buffer.v", "ecg_rom.hex",
              "golden_model.py", "weight.mi"]] + list((ROOT / "src/golden").glob("*"))

def hashes():
    return {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in PROTECTED if p.is_file()}

def main():
    global OUT
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline", action="store_true")
    parser.add_argument("--tests", nargs="+", choices=TESTS)
    parser.add_argument("--questa", default="C:/MentorGraphics/win64")
    parser.add_argument("--prim", default="C:/Gowin/Gowin_V1.9.12.01_x64/IDE/simlib/gw5a/prim_sim.v")
    parser.add_argument("--out", type=Path, default=OUT,
                        help="Separate output directory to preserve earlier PASS checkpoints")
    args = parser.parse_args()
    OUT = args.out.resolve()
    OUT.mkdir(parents=True, exist_ok=True)
    prefix = "baseline_" if args.baseline else ""
    commands = OUT / (prefix + "commands.txt")
    commands.write_text("", encoding="utf-8")
    macro = OUT / (prefix + "run.do")
    macro.write_text("onerror {quit -code 1 -f}\nonbreak {quit -code 1 -f}\n"
                     "run -all\nquit -code 0 -f\n", encoding="ascii")
    before = hashes()

    def run(argv, timeout=180):
        argv = [a.as_posix() if isinstance(a, Path) else str(a) for a in argv]
        with commands.open("a", encoding="utf-8") as f:
            f.write(subprocess.list2cmdline(argv) + "\n")
        result = subprocess.run(argv, cwd=ROOT,
                                capture_output=True, text=True, errors="replace", timeout=timeout)
        return result

    executables = {}
    for name in ("vlib", "vlog", "vsim"):
        exe = Path(args.questa) / (name + ".exe")
        if not exe.is_file():
            print("NOT RUN: missing", exe)
            return 2
        executables[name] = exe
    prim = Path(args.prim)
    if not prim.is_file():
        print("NOT RUN: missing GW5A simulation library", prim)
        return 2
    version = run([executables["vsim"], "-version"])
    print(version.stdout.strip(), flush=True)
    if version.returncode:
        print(version.stderr)
        return 2
    names = args.tests or (["control", "start_accept", "apb", "class_uart"] if args.baseline else list(TESTS))
    sources = [ROOT / "src" / p for p in RTL]
    if args.baseline:
        # Export committed sources into the output directory; never checkout or reset.
        baseline = OUT / "baseline_src"
        sources = []
        for p in RTL:
            dest = baseline / p
            dest.parent.mkdir(parents=True, exist_ok=True)
            result = subprocess.run(["git", "show", "HEAD:src/" + p], cwd=ROOT,
                                    capture_output=True, check=True)
            dest.write_bytes(result.stdout)
            sources.append(dest)
    lib = OUT / (prefix + "work")
    ini = OUT / (prefix + "modelsim.ini")
    ini.write_text("[Library]\nwork = " + lib.as_posix() + "\nothers = " +
                   (Path(args.questa).parent / "modelsim.ini").as_posix() + "\n",
                   encoding="utf-8")
    if not lib.exists():
        result = run([executables["vlib"], lib])
        if result.returncode:
            print(result.stdout, result.stderr)
            return 2
    benches = sorted({ROOT / "sim" / (TESTS[n][0] + ".sv") for n in names})
    result = run([executables["vlog"], "-modelsimini", ini, "-sv", "-work", "work", "+incdir+.",
                  *(["+define+G1_BASELINE"] if args.baseline else []),
                  "-l", OUT / (prefix + "compile.log"), prim, *sources, *benches])
    if result.returncode:
        print("FAIL compile\n", result.stdout[-12000:], result.stderr)
        return 1
    print("PASS compile", flush=True)
    failed = []
    summary = []
    for name in names:
        bench, marker, extra = TESTS[name]
        log = OUT / (prefix + name + ".log")
        result = run([executables["vsim"], "-modelsimini", ini, "-c", "-onfinish", "exit",
                      "-l", log, "-wlf", OUT / (prefix + name + ".wlf"),
                      "work." + bench, *extra, "+CAPTURE_DIR=" + OUT.as_posix(), "-do",
                      "do " + macro.relative_to(ROOT).as_posix()], timeout=300)
        content = log.read_text(encoding="utf-8", errors="replace") if log.exists() else result.stdout
        passed = result.returncode == 0 and marker in content and "** Fatal:" not in content
        status = "PASS" if passed else "FAIL"
        row = f"{name}: {status} exit={result.returncode} log={log.relative_to(ROOT)}"
        summary.append(row)
        print(row, flush=True)
        if not passed:
            failed.append(name)
            print("\n".join(content.splitlines()[-16:]), flush=True)
    if not args.baseline and not failed:
        decoder_args = [[sys.executable, "-I", "src/uart_decode.py"]]
        if "rom_uart" in names:
            decoder_args.append([sys.executable, "-I", "src/uart_decode.py", "--check",
                                 (OUT / "uart_golden.bin").as_posix()])
        for i, cmd in enumerate(decoder_args):
            result = run(cmd)
            (OUT / f"decoder_{i}.log").write_text(result.stdout + result.stderr, encoding="utf-8")
            status = "PASS" if result.returncode == 0 else "FAIL"
            print(f"decoder_{i}: {status}", flush=True)
            summary.append(f"decoder_{i}: {status} exit={result.returncode}")
            if result.returncode: failed.append(f"decoder_{i}")
    unchanged = before == hashes()
    summary.append("protected inputs unchanged: " + str(unchanged))
    (OUT / (prefix + "summary.txt")).write_text("\n".join(summary) + "\n", encoding="utf-8")
    if not unchanged:
        raise RuntimeError("Protected file changed during verification")
    return 1 if failed else 0

if __name__ == "__main__":
    raise SystemExit(main())
