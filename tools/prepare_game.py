"""Windows local preparation. Only dependency downloads use the network."""
from pathlib import Path
import argparse
import json
import os
import subprocess
from bootstrap import setup, ROOT
from common import game_check
from build_guest import build

def prepare(game, llvm, jobs=4):
    game,llvm=Path(game).resolve(),Path(llvm).resolve()
    game_check(game)
    setup()
    cargo=["cargo"]
    env=dict(os.environ)
    if os.name=="nt":
        target="x86_64-pc-windows-gnu"
        toolchain="1.99.1-"+target
        cargo += ["+"+toolchain]
        env["PATH"]=str(llvm)+os.pathsep+env.get("PATH","")
        env["CARGO_TARGET_X86_64_PC_WINDOWS_GNU_LINKER"]=str(llvm/"gcc.exe")
        lib=subprocess.check_output(["rustup","run",toolchain,"rustc","--print","target-libdir"],text=True).strip()
        runtime=Path(lib)/"self-contained"
        if not (runtime/"libgcc.a").is_file():
            raise ValueError("Install the documented Rust GNU toolchain")
        # Rust ships the GNU runtime archives omitted by LLVM-MinGW.
        env.pop("RUSTFLAGS",None)
        env["CARGO_ENCODED_RUSTFLAGS"]="\x1f".join(["-C","link-self-contained=yes","-L","native="+str(runtime)])
    base=ROOT/"build/private-game"
    source=base/"aot"
    if source.exists():
        raise ValueError("Private generated code exists; resume build_guest.py or use a fresh project checkout")
    subprocess.run(cargo+["build","--locked","--release","--manifest-path",str(ROOT/"source/aot-generator/Cargo.toml"),"--target-dir",str(ROOT/"build/generator")],check=True,env=env)
    binary=ROOT/"build/generator/release"/("rh3ds-aot-generate.exe" if os.name=="nt" else "rh3ds-aot-generate")
    subprocess.run([str(binary),str(game),str(source)],check=True)
    framework=build(source,base/"ios",llvm,jobs)
    (base/"game-source.json").write_text(json.dumps(dict(game_sha256=game_check(game),game_uploaded=False),indent=2)+"\n")
    print("Local game framework ready:",framework)

if __name__=="__main__":
    p=argparse.ArgumentParser()
    p.add_argument("--game",required=True,type=Path)
    p.add_argument("--llvm-bin",required=True,type=Path)
    p.add_argument("--jobs",default=4,type=int)
    a=p.parse_args()
    if not 1<=a.jobs<=16:
        p.error("jobs must be 1..16")
    prepare(a.game,a.llvm_bin,a.jobs)
