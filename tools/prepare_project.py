"""Copy pinned FPGA inputs into a fresh directory; does not start Vivado."""
import argparse
from pathlib import Path
import shutil

ROOT = Path(__file__).resolve().parents[1]


def prepare(destination):
    destination = Path(destination).resolve()
    if destination.is_relative_to(ROOT):
        raise ValueError('Use an external fresh build directory, not this source checkout')
    if destination.exists():
        raise FileExistsError('Refusing to overwrite an existing build directory')
    if any(c.isspace() or ord(c) > 127 for c in str(destination)):
        raise ValueError('Pinned Tcl requires an ASCII build path without spaces')
    shutil.copytree(ROOT / 'fpga', destination)
    (destination / 'reports').mkdir(exist_ok=True)
    return destination


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out', required=True)
    target = prepare(parser.parse_args().out)
    print('INPUT_COPY_ONLY:', target)
    print('In an authorized Vivado 2023.2 session, source the copied setup.tcl.')
    print('setup creates the project and IP targets, not synthesis/implementation/bitstream.')
