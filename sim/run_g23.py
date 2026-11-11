"""G1/G2.1/G2.2 invariants plus G2.3 ZC/RR, all on current RTL.

python -I sim/run_g23.py
Old test files and golden remain untouched. Review generated adaptations in
sim/g23_results/final/adaptation.patch: only independently calculated expected
numbers/paths, new port stimulus, and additional checks. No assertions removed.
Golden generation is an explicit separate command, never part of this runner.
"""
import argparse
import copy
import difflib
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import subprocess
import sys

sys.dont_write_bytecode=True
ROOT=Path(__file__).resolve().parents[1]
DEFAULT_OUT=ROOT/"sim/g23_results/final"


def load(name,path):
    spec=importlib.util.spec_from_file_location(name,ROOT/path)
    module=importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


g1=load("g1_launcher","sim/run_g1.py")
vectors=load("g23_vectors","sim/gen_g23_vectors.py")
ref=vectors.ref
original_vectors=vectors.old
TESTS=dict(g1.TESTS)
TESTS.update({
    "g21_preprocess":("tb_g21_preprocess","G21 PREPROCESS PASS",[]),
    "g21_vectors_g22_math":("tb_g21_signed_features","G21 SIGNED FEATURES PASS",[]),
    "signed_uart":("tb_g21_rom_uart","G21 ROM UART PASS",[]),
    "signed_uart_injected":("tb_g21_rom_uart","G21 ROM UART PASS",["+INJECT_CLASS"]),
    "arithmetic":("tb_g22_arithmetic","G22 ARITHMETIC PASS",[]),
    "tracker":("tb_g23_tracker","G23 TRACKER PASS",[]),
    "replay":("tb_g23_replay","G23 REPLAY PASS",[]),
    "windows":("tb_g23_windows","G23 WINDOWS PASS",[]),
    "reset_faults":("tb_g22_reset_faults","G22 RESET FAULTS PASS",[]),
})


def source_hashes():
    paths=[p for p in (ROOT/"src").rglob("*") if p.is_file() and "__pycache__" not in p.parts]
    paths+=[ROOT/"Bao_rom.gprj",ROOT/"G2_3_DESIGN_CONTRACT.txt"]
    paths+=list((ROOT/"sim").glob("*.py"))+list((ROOT/"sim").glob("*.sv"))
    return {p.relative_to(ROOT).as_posix():hashlib.sha256(p.read_bytes()).hexdigest() for p in paths}


def adapt_benches(names,out):
    folder=out/"adapted"; folder.mkdir(exist_ok=True)
    legacy=ref.make_golden("legacy")["windows"]
    fields=["rms","var","peak","zc","ptp","crest","half","max","rr","rprev","ratio","rrd"]
    differences=[]; benches=[]
    direct=["tb_g21_signed_features","tb_g22_arithmetic","tb_g22_reset_faults",
            "tb_feature_checkpoint","tb_g1_rom_golden"]
    for bench in sorted({TESTS[n][0] for n in names}):
        original=ROOT/"sim"/(bench+".sv"); before=original.read_text(); after=before
        if bench in ["tb_g1_rom_uart","tb_g1_reset"]:
            after=after.replace('"src/golden/expected_packets.sv"','"src/golden/g23_legacy/expected_packets.sv"')
        if bench=="tb_g21_rom_uart":
            after=after.replace('"src/golden/g21_signed/expected_packets.sv"','"src/golden/g23_signed/expected_packets.sv"')
            after=add_stream_checks(after)
        if bench=="tb_g21_signed_features":
            after=after.replace('"sim/g21_vectors/features.hex"','"sim/g23_vectors/g21_features.hex"').replace("frozen_math=1","math_contract_G23=1")
        if bench=="tb_g1_rom_golden":
            pattern=r"exp_("+"|".join(fields)+r")\[(\d+)\]\s*=\s*-?\d+;"
            def expected(match):
                field,index=match.group(1),int(match.group(2))
                return f"exp_{field}[{index}]={legacy[index]['features_rtl'][fields.index(field)]};"
            after,count=re.subn(pattern,expected,after); assert count==84
        if bench=="tb_feature_checkpoint":
            windows=iter(original_vectors.checkpoint_cases())
            def expected_call(match):
                return "        check_all("+", ".join(map(str,ref.features(next(windows))))+");"
            after,count=re.subn(r"^\s+check_all\([^;\n]+\);$",expected_call,after,flags=re.M)
            assert count==10 and next(windows,None) is None
        if bench in direct:
            cur=prev="16'd0"; cv=pv="1'b0"
            if bench=="tb_g1_rom_golden":
                cur="16'(exp_rr[win_id-1])"; prev="16'(exp_rprev[win_id-1])"
                cv="(exp_rr[win_id-1]!=0)"; pv="(exp_rprev[win_id-1]!=0)"
            if bench=="tb_g22_reset_faults":
                after=after.replace('reg clk=0;', 'reg g23_pair=0;\n    reg clk=0;')
                cur="(g23_pair ? 16'd300 : 16'd0)"; prev="(g23_pair ? 16'd200 : 16'd0)"; cv=pv="g23_pair"
                after=after.replace('fill(0); memory[10]=100;', 'g23_pair=1; fill(0); memory[10]=100;')
                after=after.replace('fill(-8\'sd10); launch();', 'g23_pair=0; fill(-8\'sd10); launch();')
                after=after.replace('f[10]==4096','f[10]==0')
            if bench=="tb_g22_arithmetic":
                after=after.replace('sim/g22_vectors/','sim/g23_vectors/')
                after=after.replace('integer case_id=0,', 'reg [15:0] snapshots[0:NUM_CASES*6-1];\n    integer case_id=0,')
                after=after.replace('$readmemh("sim/g23_vectors/samples.hex",samples);', '$readmemh("sim/g23_vectors/samples.hex",samples);\n        $readmemh("sim/g23_vectors/snapshots.hex",snapshots);')
                # Destroy live inputs after accepted start: results must use latch.
                cur="(start ? snapshots[case_id*6] : 16'd0)"
                prev="(start ? snapshots[case_id*6+1] : 16'd0)"
                cv='(start && snapshots[case_id*6+2][0])'
                pv='(start && snapshots[case_id*6+3][0])'
                after=after.replace('check(f[1]>=0', 'check(dut.rr_valid===snapshots[case_id*6+4][0] && dut.rr_ratio_saturated===snapshots[case_id*6+5][0],"RR validity and saturation");\n            check(f[1]>=0')
            ports=f".rr_snapshot_current({cur}),.rr_snapshot_previous({prev}),.rr_snapshot_current_valid({cv}),.rr_snapshot_previous_valid({pv}),.rr_valid(),.rr_ratio_saturated(),\n        "
            assert after.count('.read_enable(')==1
            after=after.replace('.read_enable(',ports+'.read_enable(')
        # Explicitly unused added window observation ports in legacy unit benches.
        after=re.sub(r'\.sample_cnt\(([^()]*)\)',r'.sample_cnt(\1),.stream_sample(),.stream_accept()',after)
        for token in ["assert(","assert (","check_value(","check_all(","$fatal("]:
            assert after.count(token)>=before.count(token),(bench,token)
        if after!=before:
            differences.extend(difflib.unified_diff(before.splitlines(True),after.splitlines(True),fromfile="sim/"+original.name,tofile="adapted/"+original.name))
            dest=folder/original.name; dest.write_text("// G2.3 port/expectation adapter; historical comments retained.\n"+after); benches.append(dest)
        else: benches.append(original)
    (out/"adaptation.patch").write_text("".join(differences))
    return benches


def add_stream_checks(after):
    # Additional top-level assertions, on top of every original UART/read check.
    golden=ref.make_golden("rom-centered")
    checks='\n    integer rr_events_seen=0;\n    always @(negedge clk) if(rst_n) begin\n        assert(dut.u_rr.next_sample_index==writes) else $fatal(1,"RR accepted stream count");\n        if(dut.u_rr.peak_event) begin\n            case(rr_events_seen)\n@EVENTS@\n            default: $fatal(1,"duplicate RR event");\n            endcase\n            rr_events_seen++;\n        end\n        if(dut.feat_valid) begin\n            case(features)\n@SNAPS@\n            default: $fatal(1,"unknown RR window");\n            endcase\n        end\n    end\n'
    events="\n".join(f'            {i}: assert(dut.u_rr.event_timestamp==64\'d{p}) else $fatal(1,"RR event timestamp");' for i,p in enumerate(golden['rr_events']))
    snaps=[]
    for i,w in enumerate(golden['windows']):
        s=w['rr_snapshot']
        snaps.append(f"            {i+1}: assert(dut.rr_snapshot_current=={s['current']} && dut.rr_snapshot_previous=={s['previous']} && dut.rr_snapshot_current_valid==1'b{int(s['current_valid'])} && dut.rr_snapshot_previous_valid==1'b{int(s['previous_valid'])}) else $fatal(1,\"window end RR snapshot\");")
    checks=checks.replace('@EVENTS@',events).replace('@SNAPS@','\n'.join(snaps))
    after=after.replace('endmodule',checks+'\nendmodule')
    after=after.replace('$fclose(capture);',f'assert(rr_events_seen=={len(golden["rr_events"])}) else $fatal(1,"lost RR event");\n        $fclose(capture);')
    return after


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out",type=Path,default=DEFAULT_OUT)
    parser.add_argument("--tests",nargs="+",choices=TESTS)
    args=parser.parse_args(); out=args.out.resolve(); out.relative_to(ROOT)
    out.mkdir(parents=True,exist_ok=True)
    before=source_hashes(); summary=[]; failed=[]
    commands=out/"commands.txt"; commands.write_text("")
    def run(command,timeout=300):
        argv=[v.as_posix() if isinstance(v,Path) else str(v) for v in command]
        with commands.open("a") as f: f.write(subprocess.list2cmdline(argv)+"\n")
        return subprocess.run(argv,cwd=ROOT,capture_output=True,text=True,errors="replace",timeout=timeout)
    def record(name,ok,content=""):
        row=f"{name}: {'PASS' if ok else 'FAIL'}"
        summary.append(row); print(row,flush=True)
        if content: (out/(name+".log")).write_text(content,encoding="utf-8")
        if not ok: failed.append(name)
    # Run invariants and generate only directed vectors, never packet golden.
    for name,cmd in [
        ("python_preprocess",["sim/gen_g21_vectors.py"]),
        ("python_arithmetic",["sim/gen_g22_vectors.py"]),
        ("python_stream",["sim/gen_g23_vectors.py"]),
        ("python_golden",["src/g23_reference.py","--check"]),
    ]:
        result=run([sys.executable,"-I",*cmd]); record(name,result.returncode==0,result.stdout+result.stderr)
        if result.returncode: raise RuntimeError(result.stdout+result.stderr)
    names=args.tests or list(TESTS)
    benches=adapt_benches(names,out)
    questa=Path("C:/MentorGraphics/win64")
    prim=Path("C:/Gowin/Gowin_V1.9.12.01_x64/IDE/simlib/gw5a/prim_sim.v")
    lib=out/"work"; ini=out/"modelsim.ini"; macro=out/"run.do"
    ini.write_text("[Library]\nwork = "+lib.as_posix()+"\nothers = C:/MentorGraphics/modelsim.ini\n")
    macro.write_text("onerror {quit -code 1 -f}\nonbreak {quit -code 1 -f}\nrun -all\nquit -code 0 -f\n")
    if not lib.exists():
        result=run([questa/"vlib.exe",lib]); assert result.returncode==0,result.stdout
    result=run([questa/"vlog.exe","-modelsimini",ini,"-sv","-work","work","+incdir+.",
                "-l",out/"compile.log",prim,*[ROOT/"src"/p for p in g1.RTL+["rr_tracker.v"]],*benches])
    if result.returncode: raise RuntimeError(result.stdout+result.stderr)
    print("PASS compile",flush=True)
    for name in names:
        bench,marker,extra=TESTS[name]; log=out/(name+".log")
        result=run([questa/"vsim.exe","-modelsimini",ini,"-c","-onfinish","exit", "-l",log,
                    "-wlf",out/(name+".wlf"),"work."+bench,*extra,"+CAPTURE_DIR="+out.as_posix(),
                    "-do","do "+macro.relative_to(ROOT).as_posix()])
        content=log.read_text(errors="replace") if log.exists() else result.stdout
        ok=result.returncode==0 and marker in content and "** Fatal:" not in content
        record(name,ok)
        if not ok: print("\n".join(content.splitlines()[-15:]),flush=True)
    if not failed and set(names)==set(TESTS):
        result=run([sys.executable,"-I","src/uart_decode.py"])
        record("decoder_selftest",result.returncode==0,result.stdout+result.stderr)
        decoder=load("decoder","src/uart_decode.py"); reports=[]
        for mode,stem in [("legacy","uart_golden"),("signed","uart_signed")]:
            golden=json.loads((ROOT/f"src/golden/g23_{mode}/expected_packets.json").read_text())
            data=(out/(stem+".bin")).read_bytes()
            ok,lines=decoder.check_capture(data,golden); assert ok,"\n".join(lines)
            oldpath="src/golden/expected_packets.json" if mode=="legacy" else "src/golden/g21_signed/expected_packets.json"
            assert not decoder.check_capture(data,json.loads((ROOT/oldpath).read_text()))[0]
            assert not decoder.check_capture(data,json.loads((ROOT/f"src/golden/g22_{mode}/expected_packets.json").read_text()))[0]
            corrupted=bytearray(data); corrupted[16]^=1; corrupted[32]=sum(corrupted[2:32])%256
            assert not decoder.check_capture(corrupted,golden)[0],"corruption accepted"
            injected=copy.deepcopy(golden)
            for i,w in enumerate(injected["windows"]):
                w["packet"][30]=i%4; w["packet"][32]=sum(w["packet"][2:32])%256
            filename="uart_injected.bin" if mode=="legacy" else "uart_signed_injected.bin"
            ok,extra=decoder.check_capture((out/filename).read_bytes(),injected); assert ok,"\n".join(extra)
            reports+=lines+extra+[f"PASS {mode}: stale golden and corrupted feature rejected"]
        record("decoder_captures",True,"\n".join(reports)+"\n")
    unchanged=before==source_hashes()
    summary.append("protected inputs unchanged: "+str(unchanged))
    (out/"summary.txt").write_text("\n".join(summary)+"\n")
    (out/"input_sha256.json").write_text(json.dumps(before,indent=2)+"\n")
    assert unchanged,"Source/golden changed while running regression"
    return 1 if failed else 0


if __name__=="__main__":
    raise SystemExit(main())
