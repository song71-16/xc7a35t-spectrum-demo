"""Bounded static integrity and offline software checks; no EDA/hardware."""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def static_check(root=ROOT):
    mapping = json.loads((root / 'docs/source-map.json').read_text('utf8'))
    seen = set()
    for row in mapping['files']:
        p = (root / row['path']).resolve()
        if not p.is_relative_to(root.resolve()) or row['path'] in seen:
            raise ValueError('Unsafe/duplicate inventory entry: ' + row['path'])
        seen.add(row['path'])
        if not p.is_file() or p.stat().st_size != row['bytes']:
            raise ValueError('Missing/size mismatch: ' + row['path'])
    fpga = root / 'fpga'
    tcl = (fpga / 'setup.tcl').read_text('utf8')
    paths = set('/'.join(m.split()) for m in re.findall(r'\[file join \$run_dir ([^\]]+)\]', tcl))
    paths.update(p for p in re.findall(r'\$run_dir/([A-Za-z0-9_./-]+)', tcl)
                 if p != 'project' and not p.startswith('reports/'))
    for name in paths:
        p = (fpga / name).resolve()
        if not p.is_relative_to(fpga.resolve()) or not p.exists():
            raise ValueError('Missing/outside Tcl input: ' + name)
    includes = [fpga/'source/rtl/proto', fpga/'source/migration/touch_v1/demo/rtl']
    roms = set()
    for p in (fpga/'source').rglob('*'):
        if p.suffix not in ('.v', '.sv', '.vh'): continue
        source = p.read_text('utf8', errors='replace')
        for inc in re.findall(r'`include\s+"([^"]+)"', source):
            if not any((d/inc).is_file() for d in includes): raise ValueError('Missing include: '+inc)
        roms.update(re.findall(r'"([^"\n]+\.mem)"', source))
    for rom in roms:
        if not (fpga/rom).is_file(): raise ValueError('Missing readmem input: '+rom)
    for p in (fpga/'ip').glob('*.xci'):
        obj=json.loads(p.read_text('utf8'))['ip_inst']
        if obj['gen_directory'] != '.': raise ValueError('IP output path escapes local IP directory')
    return {'scope':'static mapped files/Tcl/include/ROM/IP paths only; not a Vivado build',
            'mapped_files':len(seen), 'tcl_paths':len(paths), 'roms':sorted(roms), 'status':'PASS'}


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--static-only',action='store_true')
    parser.add_argument('--artifacts',help='Parent of a new results directory')
    args=parser.parse_args()
    result={'static':static_check()}
    if args.static_only:
        print(json.dumps(result,indent=2)); return 0
    parent=Path(args.artifacts or tempfile.gettempdir());parent.mkdir(parents=True,exist_ok=True)
    out=Path(tempfile.mkdtemp(prefix='spectrum-offline-',dir=parent))
    env=os.environ.copy();env.update(QT_QPA_PLATFORM='offscreen',PYTEST_DISABLE_PLUGIN_AUTOLOAD='1',
        PYTHONDONTWRITEBYTECODE='1',PYTHONPATH=os.pathsep.join([str(ROOT),str(ROOT/'host')]),DEMO_TEST_ARTIFACTS=str(out))
    with (out/'pytest.log').open('w',encoding='utf8') as log:
        try:
            code=subprocess.run([sys.executable,'-m','pytest','-q','--junitxml='+str(out/'junit.xml')],
                cwd=ROOT,env=env,stdout=log,stderr=subprocess.STDOUT,timeout=180).returncode
        except subprocess.TimeoutExpired: code=124
    result.update(software_exit=code,status='PASS' if code==0 else 'FAIL',artifacts=str(out))
    (out/'result.json').write_text(json.dumps(result,indent=2),encoding='utf8')
    print(json.dumps(result,indent=2));return 0 if code==0 else 1


if __name__=='__main__':raise SystemExit(main())
