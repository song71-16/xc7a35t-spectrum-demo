"""Pytest-only I/O guard; fake transports remain usable, no hardware discovery."""
import os
from pathlib import Path
import sys
import tempfile

def _audit(event, args):
    if event in ('socket.__new__', 'socket.getaddrinfo', 'socket.gethostbyname'):
        raise RuntimeError('OFFLINE_ONLY: real sockets/DNS are disabled')
    if event == 'subprocess.Popen':
        executable, argv = args[:2]
        name = Path(str(executable)).name.lower()
        # Release tests may inspect existing Git objects; never run build tools.
        read_commands = {'show', 'ls-tree', 'rev-parse', 'cat-file'}
        if name not in ('git', 'git.exe') or not isinstance(argv, (list, tuple)):
            raise RuntimeError('OFFLINE_ONLY: subprocess disabled')
        command = list(argv[1:])
        if command[:1] == ['-C']:
            command = command[2:]
        if not command or command[0] not in read_commands:
            raise RuntimeError('OFFLINE_ONLY: only Git object reads allowed')

def _blocked(*args, **kwargs):
    raise RuntimeError('OFFLINE_ONLY: real serial access/discovery disabled')

def pytest_configure(config):
    os.environ['QT_QPA_PLATFORM'] = 'offscreen'
    if 'DEMO_TEST_ARTIFACTS' not in os.environ:
        os.environ['DEMO_TEST_ARTIFACTS'] = tempfile.mkdtemp(prefix='fpga-demo-tests-')
    Path(os.environ['DEMO_TEST_ARTIFACTS']).mkdir(parents=True, exist_ok=True)
    import serial
    import serial.tools.list_ports
    serial.Serial.open = _blocked
    serial.serial_for_url = _blocked
    serial.tools.list_ports.comports = _blocked
    sys.addaudithook(_audit)
