"""Demo control scheduling; no sockets, GUI, threads or hardware access.

One owner calls this object with monotonic time. Commands/Packet retain the
existing wire ABI. WRITE is sent once; an uncertain outcome is resolved by
reading current state, never by replaying a relative or absolute edit.
"""
from __future__ import annotations

from dataclasses import dataclass
import math

from pc import protocol_constants as C
from migration.touch_v1.ethernet.host.control import Commands
from migration.touch_v1.ethernet.host.protocol import Packet


@dataclass(frozen=True)
class Flight:
    opcode: int
    intent: dict[int, int]
    deadline: float


@dataclass(frozen=True)
class WriteReceipt:
    session: int
    sequence: int
    intent: tuple[tuple[int, int], ...]
    epoch: int
    received_at: float


class ControlSession:
    POLL_SECONDS = 0.5
    WRITE_SECONDS = 0.1
    COMMAND_SECONDS = 1.0
    MAX_READ_FAILURES = 3
    REQUIRED = frozenset(r['address'] for r in C.REGISTERS)

    def __init__(self):
        self.commands: Commands | None = None
        self.flight: Flight | None = None
        self.online = False
        self.ready = False
        self.needs_reconnect = False
        self.actual: dict[int, int] = {}
        self.actual_at: float | None = None
        self.actual_sequence: int | None = None
        self.epoch: int | None = None
        self.queued: dict[int, int] = {}
        self.result = 'NONE'
        self.detail = 'Read FPGA configuration before editing'
        self.next_poll = 0.0
        self.next_write = 0.0
        self.read_failures = 0
        self.last_write_ack: dict[int, int] = {}
        self.write_receipt: WriteReceipt | None = None

    def start_session(self, session: int, now: float):
        if type(session) is not int or not 0 < session <= 0xffffffff:
            raise ValueError('session must be a nonzero u32')
        if self.commands and session == self.commands.session:
            raise ValueError('reconnect requires a new session identity')
        self.disconnect()
        self.write_receipt = None
        self.commands = Commands(session)
        self.online = True
        self.needs_reconnect = False
        self.next_poll = self.next_write = now
        self.read_failures = 0
        self.detail = 'Connected; waiting for complete FPGA readback'

    def disconnect(self):
        if self.flight and self.flight.opcode == C.CMD_WRITE:
            self.result = 'UNKNOWN'
        self.online = self.ready = False
        self.queued.clear()
        self.flight = None
        if self.commands:
            self.commands.pending = None
        self.detail = 'Disconnected; retained values are stale'

    @classmethod
    def valid_info(cls, regs: dict[int, int]) -> bool:
        if set(regs) != cls.REQUIRED or any(type(v) is not int for v in regs.values()):
            return False
        for spec in C.REGISTERS:
            value = regs[spec['address']]
            if not 0 <= value <= 0xffffffff:
                return False
            if 'min' in spec and value < spec['min']:
                return False
            if 'max' in spec and value > spec['max']:
                return False
            if 'allowed' in spec and value not in spec['allowed']:
                return False
        return (regs[256] > 0 and regs[257] == 512 and regs[258] == 31
                and regs[259] == 16 and regs[260] == 1 and regs[261] == 1
                and regs[17] + (regs[19] if regs[1] == 2 else 0) <= 32767)

    def frequency_step(self, hz: float) -> int:
        if not self.ready:
            raise RuntimeError('FPGA configuration is not confirmed')
        fs = self.actual[256]
        if not math.isfinite(hz) or not 0 <= hz < fs / 2:
            raise ValueError('frequency must be finite and within [0, Fs/2)')
        step = round(hz * (1 << 32) / fs)
        if not 0 <= step <= 0x7fffffff:
            raise ValueError('frequency rounds outside the DDS range')
        return step

    def edit(self, values: dict[int, int]):
        """Only explicitly edited fields; never copy unedited actual values."""
        if not self.online or not self.ready:
            raise RuntimeError('read confirmed FPGA state before editing')
        if not values or any(type(k) is not int for k in values) or not set(values) <= {16, 17}:
            raise ValueError('demo edits support only DDS A frequency and amplitude')
        for address, value in values.items():
            maximum = 0x7fffffff if address == 16 else 32767
            if type(value) is not int or not 0 <= value <= maximum:
                raise ValueError('DDS parameter outside its integer range')
        self.queued.update(values)
        self.detail = 'Edited fields queued; actual values require FPGA confirmation'

    def _unknown(self, detail: str):
        self.ready = False
        self.queued.clear()
        self.result = 'UNKNOWN'
        self.detail = detail
        self.next_poll = 0.0

    def _read_failed(self, detail: str):
        self._unknown(detail)
        self.read_failures += 1
        if self.read_failures >= self.MAX_READ_FAILURES:
            self.disconnect()
            self.needs_reconnect = True

    def tick(self, now: float) -> bytes | None:
        if not self.online:
            return None
        assert self.commands is not None
        if self.flight:
            if now < self.flight.deadline:
                return None
            opcode = self.flight.opcode
            self.commands.pending = None
            self.flight = None
            if opcode == C.CMD_WRITE:
                self._unknown('WRITE outcome unknown; querying actual state without replay')
            else:
                self._read_failed('INFO timed out; actual values are stale')
            if not self.online:
                return None
        if self.commands.sequence == 0xffffffff:
            self.disconnect()
            self.needs_reconnect = True
            self.detail = 'Sequence exhausted; new session and INFO required'
            return None
        if not self.ready or now >= self.next_poll:
            opcode, intent = C.CMD_INFO, {}
        elif self.queued and now >= self.next_write:
            opcode, intent = C.CMD_WRITE, dict(self.queued)
            self.queued.clear()
            self.next_write = now + self.WRITE_SECONDS
            self.write_receipt = None
            self.result = 'PENDING'
        else:
            return None
        wire = self.commands.request(opcode, sorted(intent.items()), now)
        self.flight = Flight(opcode, intent, now + self.COMMAND_SECONDS)
        return wire

    def receive(self, packet: Packet, now: float) -> bool:
        if not self.online or not self.flight or not self.commands:
            return False
        # Deadlines are enforced even if transport delivers a late ACK before tick.
        if now >= self.flight.deadline:
            return False
        flight = self.flight
        try:
            response = self.commands.accept(packet)
        except ValueError:
            return False
        if response is None:
            return False
        self.flight = None
        status, regs = response
        if flight.opcode == C.CMD_INFO:
            if status != C.ERR_OK or not self.valid_info(regs):
                self._read_failed('INFO rejected or incomplete/invalid; actual values remain stale')
                return True
            self.actual = dict(regs)
            self.ready = True
            self.read_failures = 0
            self.next_poll = now + self.POLL_SECONDS
            # A read confirms current values, not the historical outcome of a lost WRITE.
            self.detail = 'FPGA actual values confirmed by INFO'
        elif status != C.ERR_OK:
            self.result = 'FAILED'
            self.detail = f'FPGA rejected WRITE, status={status}; querying actual state'
            self.queued.clear()
            self.ready = False
            self.next_poll = 0.0
            return True
        elif regs != flight.intent:
            self._unknown('WRITE ACK values differ from intent; querying actual state')
            return True
        else:
            self.last_write_ack = dict(regs)
            self.write_receipt = WriteReceipt(
                packet.session, packet.frame, tuple(sorted(flight.intent.items())),
                self.commands.epoch, now)
            self.result = 'APPLIED'
            self.detail = 'WRITE confirmed by FPGA; refreshing complete actual snapshot'
            self.ready = False
            self.next_poll = 0.0
            return True
        self.actual_at = now
        self.actual_sequence = packet.frame
        self.epoch = self.commands.epoch
        return True
