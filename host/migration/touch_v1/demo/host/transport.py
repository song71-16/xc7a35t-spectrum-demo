"""Demo derivative of ethernet.host.transport; same image and command protocol.

Socket/select/time/session factories are injectable for offline integration tests.
ControlSession belongs only to the worker; UI receives copied, session-tagged data.
"""
from __future__ import annotations

import queue
import secrets
import select
import socket
import threading
import time

from migration.touch_v1.ethernet.host.protocol import Assembler, Packet, Kind, IMAGE_PORT, CONTROL_PORT
from migration.touch_v1.ethernet.host.transport import transient_network_error
from .control_session import ControlSession


class Receiver(threading.Thread):
    CONTROL_GAP_SECONDS = 0.005
    def __init__(self, bind, board, *, clock=time.monotonic, socket_factory=None,
                 selector=select.select, session_factory=lambda: secrets.randbits(32) or 1,
                 sleeper=time.sleep):
        super().__init__(daemon=True)
        self.bind, self.board = bind, board
        self.clock, self.socket_factory = clock, socket_factory or socket.socket
        self.selector, self.session_factory = selector, session_factory
        self.sleeper = sleeper
        self.stop_event = threading.Event()
        self.events = queue.Queue(maxsize=32)
        self.lock = threading.Lock()
        self.latest = None
        self.stats = {}
        self.connected = self.ready = False
        self.token = (0, 0)
        self._edits = {}
        self._stream = None
        self.last_error = ''

    def event(self, kind, value):
        try:self.events.put_nowait((kind, self.token, value))
        except queue.Full:
            self.last_error = 'UI event queue full; worker stopped'
            self.stop_event.set()

    def submit_edits(self, token, values):
        with self.lock:
            if token != self.token or not self.ready or self.stop_event.is_set():
                return False
            if not values or not set(values) <= {16, 17}:
                return False
            self._edits.update(values)  # at most two fields; latest explicit edit wins
            return True

    def request_stream(self, token, enabled):
        with self.lock:
            if token != self.token or not self.connected or self.stop_event.is_set():
                return False
            self._stream = bool(enabled)
            return True

    def run(self):
        sockets = []
        control = ControlSession()
        last_state = None
        desired_stream = 0
        initialized = False
        session = 0
        assembler = None
        last_hello = last_heartbeat = last_peer = 0.0
        next_send = 0.0

        def publish():
            nonlocal last_state
            state = dict(connected=self.connected, ready=self.connected and control.ready,
                         actual=dict(control.actual) if initialized else {},
                         actual_at=control.actual_at if initialized else None,
                         sequence=control.actual_sequence if initialized else None,
                         epoch=control.epoch if initialized else None,
                         result=control.result, detail=control.detail,
                         write_receipt=control.write_receipt,
                         in_flight=None if control.flight is None else control.flight.opcode,
                         queued=dict(control.queued), stream=bool(desired_stream))
            with self.lock:self.ready = state['ready']
            if state != last_state:
                last_state = state
                # Separate copies prevent an event consumer from modifying this cache.
                self.event('state', {**state, 'actual':dict(state['actual']), 'queued':dict(state['queued'])})

        def renew():
            nonlocal session, assembler, initialized, desired_stream, last_state
            nonlocal last_hello, last_heartbeat, last_peer
            previous = session
            for _ in range(4):
                session = self.session_factory()
                if type(session) is int and 0 < session <= 0xffffffff and session != previous:
                    break
            else:raise RuntimeError('Failed to generate a fresh nonzero session identity')
            control.disconnect()
            self.connected = False
            initialized = False
            desired_stream = 0
            with self.lock:
                self.ready = False
                self.token = (self.token[0] + 1, session)
                self._edits.clear();self._stream = None;self.latest = None
            assembler = Assembler(session)
            last_hello = last_heartbeat = self.clock() - 1
            last_peer = self.clock()
            last_state = None
            self.event('session', None)
            publish()

        def wait_send_slot(*, closing=False):
            # Single-frame FPGA receive storage: avoid host control bursts.
            # No queued command can survive a stop or session transition.
            while self.clock() < next_send:
                if self.stop_event.is_set() and not closing:return False
                self.sleeper(max(0.0,next_send-self.clock()))
            return closing or not self.stop_event.is_set()

        def send(wire, *, closing=False):
            nonlocal next_send
            if not wait_send_slot(closing=closing):return
            try:control_socket.sendto(wire, (self.board, CONTROL_PORT))
            except OSError as exc:
                if not transient_network_error(exc):raise
                # A failed WRITE send is not proof it never reached FPGA; let deadline query it.
                self.event('notice', 'Transient network error; outcome waits for FPGA readback')
            finally:
                next_send = self.clock() + self.CONTROL_GAP_SECONDS

        try:
            for port in (IMAGE_PORT, CONTROL_PORT):
                s = self.socket_factory(socket.AF_INET, socket.SOCK_DGRAM)
                sockets.append(s)
                s.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 8 * 1024 * 1024)
                if hasattr(socket, 'SIO_UDP_CONNRESET'):s.ioctl(socket.SIO_UDP_CONNRESET, False)
                s.bind((self.bind, port));s.setblocking(False)
            image_socket, control_socket = sockets
            renew()
            while not self.stop_event.is_set():
                now = self.clock()
                if self.connected and (now - last_peer > 3 or control.needs_reconnect):
                    self.event('disconnected', 'Connection expired; retained image and values are stale')
                    renew()
                if not self.connected and now - last_hello >= 1:
                    send(Packet(Kind.HELLO, session).encode());last_hello = now
                if self.connected:
                    if now - last_heartbeat >= 1:
                        send(Packet(Kind.HEARTBEAT, session, payload=bytes([desired_stream])).encode())
                        last_heartbeat = now
                    with self.lock:
                        edits, self._edits = self._edits, {}
                        stream, self._stream = self._stream, None
                    if edits:
                        if control.ready:
                            try:control.edit(edits)
                            except (RuntimeError, ValueError) as exc:
                                self.event('edit_rejected', dict(values=dict(edits), reason=str(exc)))
                        else:
                            self.event('edit_rejected', dict(values=dict(edits), reason='Readiness changed; edit not admitted, submit again after readback'))
                    if stream is not None:
                        if initialized:
                            desired_stream = int(stream)
                            send(Packet(Kind.STREAM, session, payload=bytes([desired_stream])).encode())
                        else:self.event('notice', 'Stream waits for initial complete FPGA readback')
                    # Start a command deadline only after its send slot is available.
                    if not wait_send_slot():break
                    wire = control.tick(self.clock())
                    if wire is not None:send(wire)  # at most one scheduled command per loop
                    publish()
                readable, _, _ = self.selector(sockets, [], [], .005)
                for s in readable:
                    for _ in range(256):
                        try:data, addr = s.recvfrom(2048)
                        except BlockingIOError:break
                        except OSError as exc:
                            if transient_network_error(exc):break
                            raise
                        if addr != (self.board, IMAGE_PORT if s is image_socket else CONTROL_PORT):continue
                        received_at = self.clock()
                        if s is image_socket:
                            image = assembler.add(data, received_at)
                            if image is not None:
                                with self.lock:self.latest = (self.token, image, received_at)
                            continue
                        try:
                            packet = Packet.decode(data)
                            if packet.session != session:continue
                            if packet.kind == Kind.HELLO_ACK and not self.connected:
                                if packet.payload != b'\x01':
                                    self.event('notice', 'FPGA has not confirmed gigabit full duplex');continue
                                self.connected = True
                                last_peer = received_at
                                control.start_session(session, received_at)
                            elif self.connected and packet.kind in (Kind.HEARTBEAT, Kind.RESPONSE):
                                last_peer = received_at
                            if control.receive(packet, self.clock()) and control.ready and not initialized:
                                initialized = True;desired_stream = 1
                                send(Packet(Kind.STREAM, session, payload=b'\x01').encode())
                            publish()
                        except ValueError:self.event('notice', 'Invalid control datagram rejected')
                assembler.expire(self.clock())
                with self.lock:self.stats = dict(assembler.stats)
        except Exception as exc:
            self.last_error = f'{type(exc).__name__}: {exc}'
            self.event('error', self.last_error)
        finally:
            if self.connected:
                try:send(Packet(Kind.STREAM, session, payload=b'\x00').encode(), closing=True)
                except OSError:pass
            control.disconnect();self.connected = False
            publish()
            for s in sockets:s.close()
            self.event('stopped', self.last_error or 'Receiver stopped')
