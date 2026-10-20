"""Build the host-only software HEVC provenance probe against installed FFmpeg."""
import argparse
import hashlib
import json
from pathlib import Path
import shlex
import shutil
import subprocess


def build(output):
    output=Path(output).resolve();output.mkdir(parents=True,exist_ok=False)
    source=Path(__file__).with_name('decode_layers.c')
    flags=shlex.split(subprocess.check_output(['pkg-config','--cflags','--libs','libavcodec','libavutil'],text=True))
    compiler=shutil.which('cc')
    if not compiler:raise RuntimeError('C compiler unavailable')
    binary=output/'yl-decode-layers'
    command=[compiler,'-std=c11','-D_POSIX_C_SOURCE=200809L','-O2','-Wall','-Wextra','-Werror',str(source),'-o',str(binary),*flags]
    subprocess.run(command,check=True)
    def digest(path):return hashlib.sha256(path.read_bytes()).hexdigest()
    receipt=dict(sourceSha256=digest(source),binarySha256=digest(binary),
                 compiler=subprocess.check_output([compiler,'--version'],text=True).splitlines()[0],
                 ffmpegModules=subprocess.check_output(['pkg-config','--modversion','libavcodec','libavutil'],text=True).splitlines(),
                 command=command)
    (output/'build.json').write_text(json.dumps(receipt,indent=2)+'\n')
    return receipt

if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--output',type=Path,required=True)
    print(json.dumps(build(p.parse_args().output),indent=2))
