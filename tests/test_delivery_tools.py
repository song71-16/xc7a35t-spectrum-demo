import importlib
from pathlib import Path
import socket
import pytest
from tools.launch_pc import validate_addresses
from tools.prepare_project import prepare


def test_missing_adapter_does_not_open_socket(monkeypatch):
    import psutil
    from tools.launch_pc import local_preflight
    monkeypatch.setattr(psutil, 'net_if_addrs', lambda: {})
    with pytest.raises(RuntimeError, match='not assigned'):
        local_preflight('192.168.10.1')


def test_busy_port_closes_local_handles(monkeypatch):
    import psutil
    from types import SimpleNamespace
    from tools.launch_pc import local_preflight
    monkeypatch.setattr(psutil, 'net_if_addrs', lambda: {'mock': [SimpleNamespace(family=socket.AF_INET, address='192.168.10.1')]})
    monkeypatch.setattr(psutil, 'net_if_stats', lambda: {'mock': SimpleNamespace(isup=True)})
    handles=[]
    class FakeSocket:
        def __init__(self,*args): self.closed=False;handles.append(self)
        def setsockopt(self,*args): pass
        def bind(self,address):
            if address[1]==50001: raise OSError('port already used')
        def close(self):self.closed=True
    monkeypatch.setattr(socket, 'socket', FakeSocket)
    with pytest.raises(OSError,match='port already used'):
        local_preflight('192.168.10.1')
    assert len(handles)==2 and all(s.closed for s in handles)


@pytest.mark.parametrize('bind,board,prefix',[
    ('0.0.0.0','192.168.10.2',24),('192.168.10.1','192.168.10.1',24),
    ('127.0.0.1','127.0.0.2',24),('192.168.10.1','192.168.11.2',24),
    ('192.168.10.1','192.168.10.255',24),('bad','192.168.10.2',24)])
def test_invalid_addresses(bind,board,prefix):
    with pytest.raises(ValueError):validate_addresses(bind,board,prefix)


def test_default_addresses():
    assert str(validate_addresses('192.168.10.1','192.168.10.2',24))=='192.168.10.0/24'


def test_existing_build_preserved(tmp_path):
    with pytest.raises(FileExistsError):prepare(tmp_path)


def test_real_socket_forbidden():
    with pytest.raises(RuntimeError,match='OFFLINE_ONLY'):socket.socket()


def test_runtime_import_closure_offline():
    for name in ('pc.proto','migration.touch_v1.demo.host.app','migration.touch_v1.demo.host.transport',
                 'migration.touch_v1.ethernet.host.protocol','migration.touch_v1.ethernet.host.control'):
        importlib.import_module(name)
