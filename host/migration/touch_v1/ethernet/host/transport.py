"""Bounded UDP worker with no Qt dependency; usable by tests and headless tools."""
from __future__ import annotations
import queue
import errno
import secrets
import select
import socket
import threading
import time
from pc import protocol_constants as C
from .protocol import Assembler, Packet, Kind, IMAGE_PORT, CONTROL_PORT
from .control import Commands


def transient_network_error(exc: OSError) -> bool:
    # A cable/link transition can raise an error on an already-bound Windows
    # UDP socket. Keep the worker alive so its session timeout can reconnect.
    codes = {errno.ENETDOWN, errno.ENETUNREACH, errno.EHOSTUNREACH,
             errno.ECONNRESET, errno.ECONNREFUSED, 10050, 10051, 10054, 10061, 10064, 10065}
    return exc.errno in codes or getattr(exc, 'winerror', None) in codes


class Receiver(threading.Thread):
    def __init__(self, bind: str, board: str):
        super().__init__(daemon=True)
        self.bind, self.board = bind, board
        self.stop_event = threading.Event()
        self.actions = queue.Queue(maxsize=8)
        self.events = queue.Queue(maxsize=32)
        self.lock = threading.Lock()
        self.latest = None
        self.stats = {}
        self.connected = False
        self.last_image = 0.0

    def event(self, kind, value):
        try:
            self.events.put_nowait((kind, value))
        except queue.Full:
            # UI events are bounded. A saturated consumer must reconnect.
            self.stop_event.set()

    def run(self):
        sockets = []
        try:
            for port in (IMAGE_PORT, CONTROL_PORT):
                s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
                sockets.append(s)
                s.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 8 * 1024 * 1024)
                if hasattr(socket, 'SIO_UDP_CONNRESET'):
                    s.ioctl(socket.SIO_UDP_CONNRESET, False)
                s.bind((self.bind, port))
                s.setblocking(False)
            image_socket, control_socket = sockets
            self.event('info', f'接收缓存 {image_socket.getsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF)} 字节')
            def send(wire):
                try:
                    control_socket.sendto(wire, (self.board, CONTROL_PORT))
                except OSError as exc:
                    if not transient_network_error(exc):
                        raise
            session = secrets.randbits(32) or 1
            assembler, commands = Assembler(session), Commands(session)
            last_hello = last_heartbeat = last_peer = 0.0
            initialized = False
            desired_stream = 0
            while not self.stop_event.is_set():
                now = time.monotonic()
                if not self.connected and now - last_hello >= 1:
                    send(Packet(Kind.HELLO, session).encode())
                    last_hello = now
                if self.connected and now - last_peer > 3:
                    self.connected = False
                    initialized = False
                    desired_stream = 0
                    session = secrets.randbits(32) or 1
                    assembler, commands = Assembler(session), Commands(session)
                    while not self.actions.empty():
                        self.actions.get_nowait()
                    self.event('disconnected', '连接中断；保留最后完整画面，正在重连')
                if self.connected:
                    if now - last_heartbeat >= 1:
                        send(Packet(Kind.HEARTBEAT, session, payload=bytes([desired_stream])).encode())
                        last_heartbeat = now
                    try:
                        retry = commands.poll(now)
                        if retry:
                            send(retry)
                    except TimeoutError as exc:
                        self.event('error', str(exc))
                        last_peer = 0  # force a new session and INFO readback
                    if commands.pending is None:
                        try:
                            action, value = self.actions.get_nowait()
                        except queue.Empty:
                            pass
                        else:
                            if action == 'stream':
                                desired_stream = value
                                send(Packet(Kind.STREAM, session, payload=bytes([value])).encode())
                            elif initialized:
                                opcode, entries = value
                                send(commands.request(opcode, entries, now))
                                self.event('busy', True)
                readable, _, _ = select.select(sockets, [], [], .005)
                for s in readable:
                    # Bounded batches leave time for heartbeats and commands under load.
                    for _ in range(256):
                        try:
                            data, addr = s.recvfrom(2048)
                        except BlockingIOError:
                            break
                        except OSError as exc:
                            if transient_network_error(exc):
                                break
                            raise
                        if addr != (self.board, IMAGE_PORT if s is image_socket else CONTROL_PORT):
                            continue
                        if s is image_socket:
                            image = assembler.add(data, now)
                            if image is not None:
                                with self.lock:
                                    self.latest = image
                                    self.last_image = now
                            continue
                        try:
                            p = Packet.decode(data)
                            if p.session != session:
                                continue
                            if p.kind == Kind.HELLO_ACK and not self.connected:
                                if p.payload != b'\x01':
                                    self.event('error', '开发板未报告千兆全双工链路')
                                    continue
                                self.connected = True
                                last_peer = now
                                send(commands.request(C.CMD_INFO, [], now))
                                self.event('info', '网络已连接，正在读取设备配置')
                            elif p.kind in (Kind.HEARTBEAT, Kind.RESPONSE):
                                last_peer = now
                            response = commands.accept(p)
                            if response:
                                status, regs = response
                                if status:
                                    self.event('error', f'设备拒绝命令，错误码 {status}；配置未确认改变')
                                else:
                                    self.event('registers', (regs, commands.epoch))
                                    if not initialized:
                                        initialized = True
                                        desired_stream = 1
                                        send(Packet(Kind.STREAM, session, payload=b'\x01').encode())
                                self.event('busy', False)
                        except ValueError:
                            self.event('error', '收到无效控制应答')
                assembler.expire(now)
                with self.lock:
                    self.stats = dict(assembler.stats)
            if self.connected:
                send(Packet(Kind.STREAM, session, payload=b'\x00').encode())
        except OSError as exc:
            self.event('error', f'网络错误：{exc}。检查网卡静态地址及端口占用。')
        finally:
            self.connected = False
            for s in sockets:
                s.close()

