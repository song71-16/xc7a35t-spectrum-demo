"""Portable launcher. Preflight checks local resources; never edits networking."""
import argparse
import importlib.metadata
import ipaddress
import os
from pathlib import Path
import socket
import sys

ROOT = Path(__file__).resolve().parents[1]


def validate_addresses(bind, board, prefix):
    local = ipaddress.IPv4Address(bind)
    remote = ipaddress.IPv4Address(board)
    network = ipaddress.IPv4Network(f'{local}/{prefix}', strict=False)
    if local == remote or any(a.is_unspecified or a.is_multicast or a.is_loopback for a in (local, remote)):
        raise ValueError('Use two distinct unicast LAN IPv4 addresses')
    if remote not in network or any(a in (network.network_address, network.broadcast_address) for a in (local, remote)):
        raise ValueError('PC and board must use usable addresses in the configured subnet')
    return network


def dependencies():
    if sys.version_info[:2] != (3, 13):
        raise RuntimeError('Validated host profile uses Python 3.13; install requirements.txt in a project venv')
    return {name: importlib.metadata.version(name) for name in ('PySide6', 'psutil')}


def local_preflight(bind, ports=(50000, 50001)):
    import psutil
    matches = [name for name, addresses in psutil.net_if_addrs().items()
               if any(a.family == socket.AF_INET and a.address == bind for a in addresses)]
    if not matches:
        raise RuntimeError(f'PC address {bind} is not assigned. Configure it manually; no settings changed.')
    stats = psutil.net_if_stats()
    if not any(name in stats and stats[name].isup for name in matches):
        raise RuntimeError('Matching network adapter is down')
    # Local binds only: no packets sent and no board discovery. Ports are released
    # before the real application starts; another process could race this check.
    handles = []
    try:
        for port in ports:
            s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            handles.append(s)
            if os.name == 'nt':
                s.setsockopt(socket.SOL_SOCKET, socket.SO_EXCLUSIVEADDRUSE, 1)
            s.bind((bind, port))
    finally:
        for handle in handles:
            handle.close()
    return matches


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--bind', default=os.environ.get('DEMO_BIND', '192.168.10.1'))
    parser.add_argument('--board', default=os.environ.get('DEMO_BOARD', '192.168.10.2'))
    parser.add_argument('--prefix', type=int, default=24)
    parser.add_argument('--offline-check', action='store_true', help='Dependencies/address syntax only, no sockets')
    parser.add_argument('--preflight', action='store_true', help='Local adapter/port checks only; do not start UI')
    args = parser.parse_args()
    validate_addresses(args.bind, args.board, args.prefix)
    print('Dependencies:', dependencies())
    print('Addresses:', args.bind, '->', args.board, '(board firmware must match)')
    if args.offline_check:
        print('OFFLINE_CHECK_PASS; adapter, ports and board not checked')
        return 0
    print('Local adapters:', local_preflight(args.bind))
    if args.preflight:
        print('LOCAL_PREFLIGHT_PASS; no board packets sent; firewall/board response not verified')
        return 0
    sys.path.insert(0, str(ROOT / 'host'))
    from migration.touch_v1.demo.host.app import main as app_main
    sys.argv = [sys.argv[0], '--bind', args.bind, '--board', args.board]
    return app_main()


if __name__ == '__main__':
    try:
        raise SystemExit(main())
    except (OSError, ValueError, RuntimeError, importlib.metadata.PackageNotFoundError) as error:
        print('START_BLOCKED:', error, file=sys.stderr)
        raise SystemExit(1)
