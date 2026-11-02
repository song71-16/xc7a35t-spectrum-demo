"""Bounded streaming parser, frame grouping, and command codec (stdlib only)."""
from __future__ import annotations

from collections import Counter, OrderedDict
from dataclasses import dataclass
import struct
import time

from . import protocol_constants as C

HEADER = struct.Struct(C.HEADER_FORMAT)
STATUS = struct.Struct(C.STATUS_FORMAT)
KNOWN_TYPES = {C.TYPE_TIME, C.TYPE_SPECTRUM, C.TYPE_STATUS, C.TYPE_COMMAND, C.TYPE_RESPONSE}
CRC_TABLE = []
for _index in range(256):
    _crc = _index << 8
    for _bit in range(8):
        _crc = ((_crc << 1) ^ 0x1021) & 0xFFFF if _crc & 0x8000 else (_crc << 1) & 0xFFFF
    CRC_TABLE.append(_crc)
CRC_TABLE = tuple(CRC_TABLE)


def crc16(data: bytes | bytearray | memoryview) -> int:
    crc = 0xFFFF
    for value in data:
        crc = ((crc << 8) ^ CRC_TABLE[((crc >> 8) ^ value) & 255]) & 0xFFFF
    return crc


def frame_is_newer(candidate: int, previous: int) -> bool:
    return 0 < ((candidate - previous) & 0xFFFFFFFF) < 0x80000000


@dataclass(frozen=True)
class Frame:
    type: int
    frame_id: int
    config_epoch: int
    payload: bytes

    def encode(self) -> bytes:
        if self.type not in KNOWN_TYPES or len(self.payload) > C.MAX_PAYLOAD:
            raise ValueError("unknown type or oversized payload")
        head = HEADER.pack(C.SYNC, C.VERSION, self.type, len(self.payload), self.frame_id, self.config_epoch)
        body = head[2:] + self.payload
        return C.SYNC + body + struct.pack("<H", crc16(body))


class StreamParser:
    """Rescan one byte after invalid candidates; never trust unverified lengths."""

    def __init__(self, inter_byte_timeout: float = .1, subframe_timeout: float = .25):
        self.buffer = bytearray()
        self.stats: Counter = Counter()
        self.inter_byte_timeout = inter_byte_timeout
        self.subframe_timeout = subframe_timeout
        self._last_byte: float | None = None
        self._started: float | None = None

    def feed(self, data: bytes = b"", now: float | None = None) -> list[Frame]:
        now = time.monotonic() if now is None else now
        result = self._parse(now)
        if self.buffer and ((self._last_byte is not None and now - self._last_byte > self.inter_byte_timeout) or (self._started is not None and now - self._started > self.subframe_timeout)):
            self.stats["timeout"] += 1
            del self.buffer[0]
            self._started = None
            result.extend(self._parse(now))
            # Unverified partial candidates from an expired read must not block recovery.
            if self.buffer:
                self.stats["discarded_bytes"] += len(self.buffer)
                self.buffer.clear()
        if data:
            self._last_byte = now
        # The input chunk is not retained wholesale, keeping parser storage bounded.
        for offset in range(0, len(data), C.MAX_PAYLOAD + 14):
            self.buffer.extend(data[offset:offset + C.MAX_PAYLOAD + 14])
            result.extend(self._parse(now))
        return result

    def _parse(self, now: float) -> list[Frame]:
        result = []
        while self.buffer:
            pos = self.buffer.find(C.SYNC)
            if pos < 0:
                preserve = 1 if self.buffer[-1] == C.SYNC[0] else 0
                self.stats["discarded_bytes"] += len(self.buffer) - preserve
                if preserve:
                    self.buffer[:] = self.buffer[-1:]
                else:
                    self.buffer.clear()
                self._started = now if preserve else None
                break
            if pos:
                self.stats["discarded_bytes"] += pos
                del self.buffer[:pos]
                self._started = None
            if self._started is None:
                self._started = now
            if len(self.buffer) < HEADER.size:
                break
            _, version, kind, size, fid, epoch = HEADER.unpack_from(self.buffer)
            if version != C.VERSION or kind not in KNOWN_TYPES or size > C.MAX_PAYLOAD:
                self.stats["header_error"] += 1
                del self.buffer[0]
                self._started = None
                continue
            if kind == C.TYPE_STATUS and size != STATUS.size:
                self.stats["length_error"] += 1
                del self.buffer[0]
                self._started = None
                continue
            total = HEADER.size + size + 2
            if len(self.buffer) < total:
                break
            expected = struct.unpack_from("<H", self.buffer, total - 2)[0]
            if crc16(self.buffer[2:total - 2]) != expected:
                self.stats["crc_error"] += 1
                del self.buffer[0]
                self._started = None
                continue
            result.append(Frame(kind, fid, epoch, bytes(self.buffer[HEADER.size:total - 2])))
            self.stats["frames"] += 1
            del self.buffer[:total]
            self._started = None
        return result


@dataclass(frozen=True)
class Status:
    sample_rate_hz: int = 100_000_000
    decimation: int = 1
    time_stride: int = 1
    fft_size: int = 512
    fir_taps: int = 31
    data_width: int = 16
    window: int = 1
    time_source: int = 1
    flags: int = 0
    timestamp_cycles: int = 0
    processing_cycles: int = 0
    peak_bin: int = 0
    peak_fraction_q15: int = 0
    peak_dbfs_q8_8: int = -32768
    noise_floor_dbfs_q8_8: int = -32768
    trigger_request_count: int = 0
    accepted_frame_count: int = 0
    trigger_reject_count: int = 0
    processing_fail_count: int = 0
    tx_group_drop_count: int = 0
    overflow_count: int = 0
    capture_overwrite_count: int = 0

    def encode(self) -> bytes:
        return STATUS.pack(*(getattr(self, name) for name in C.STATUS_FIELDS))

    @classmethod
    def decode(cls, payload: bytes) -> "Status":
        if len(payload) != STATUS.size:
            raise ValueError("status must contain 64 bytes")
        return cls(**dict(zip(C.STATUS_FIELDS, STATUS.unpack(payload))))

    def validate(self) -> None:
        if self.fft_size not in (256, 512, 1024) or not self.sample_rate_hz or not self.decimation or self.time_stride not in (1, 2, 4):
            raise ValueError("unsupported sampling metadata")
        if self.fir_taps not in (11, 31, 63) or self.data_width not in (8, 12, 16) or self.window != 1 or self.time_source not in (0, 1):
            raise ValueError("unsupported compiled metadata")
        if self.peak_bin > self.fft_size // 2:
            raise ValueError("peak bin out of range")

    @property
    def frequency_hz(self) -> float:
        return (self.peak_bin + self.peak_fraction_q15 / 32768) * self.sample_rate_hz / self.decimation / self.fft_size


@dataclass(frozen=True)
class FrameGroup:
    frame_id: int
    config_epoch: int
    time_frame: Frame
    spectrum_frame: Frame
    status_frame: Frame
    status: Status

    @property
    def samples(self) -> tuple[int, ...]:
        return struct.unpack("<" + "h" * (len(self.time_frame.payload) // 2), self.time_frame.payload)

    @property
    def spectrum_dbfs(self) -> tuple[float, ...]:
        return tuple(v / 256 for v in struct.unpack("<" + "h" * (len(self.spectrum_frame.payload) // 2), self.spectrum_frame.payload))

    def frames(self) -> tuple[Frame, ...]:
        return self.time_frame, self.spectrum_frame, self.status_frame


class GroupAssembler:
    def __init__(self, timeout: float = .5, max_pending: int = 8):
        if max_pending < 1:
            raise ValueError("max_pending must be positive")
        self.timeout = timeout
        self.max_pending = max_pending
        self.pending: OrderedDict = OrderedDict()
        self.recent: OrderedDict = OrderedDict()
        self.stats: Counter = Counter()
        self._last_complete_id: int | None = None

    def expire(self, now: float | None = None) -> None:
        now = time.monotonic() if now is None else now
        for key, (started, _) in list(self.pending.items()):
            if now - started > self.timeout:
                del self.pending[key]
                self.stats["incomplete_group"] += 1

    def add(self, frame: Frame, now: float | None = None) -> FrameGroup | None:
        now = time.monotonic() if now is None else now
        self.expire(now)
        if frame.type not in (C.TYPE_TIME, C.TYPE_SPECTRUM, C.TYPE_STATUS):
            return None
        key = frame.frame_id, frame.config_epoch
        if key in self.recent:
            self.stats["duplicate_subframe"] += 1
            return None
        if key not in self.pending:
            if len(self.pending) >= self.max_pending:
                self.pending.popitem(last=False)
                self.stats["pending_eviction"] += 1
                self.stats["incomplete_group"] += 1
            self.pending[key] = now, {}
        subframes = self.pending[key][1]
        if frame.type in subframes:
            self.stats["duplicate_subframe"] += 1
            return None
        subframes[frame.type] = frame
        if len(subframes) != 3:
            return None
        del self.pending[key]
        try:
            status = Status.decode(subframes[C.TYPE_STATUS].payload)
            status.validate()
            if len(subframes[C.TYPE_TIME].payload) != 2 * (status.fft_size // status.time_stride):
                raise ValueError("time length disagrees with status")
            if len(subframes[C.TYPE_SPECTRUM].payload) != 2 * (status.fft_size // 2 + 1):
                raise ValueError("spectrum length disagrees with status")
        except ValueError:
            self.stats["length_metadata_error"] += 1
            return None
        group = FrameGroup(*key, subframes[C.TYPE_TIME], subframes[C.TYPE_SPECTRUM], subframes[C.TYPE_STATUS], status)
        self.recent[key] = None
        if len(self.recent) > 32:
            self.recent.popitem(last=False)
        self.stats["complete_groups"] += 1
        if self._last_complete_id is not None:
            distance = (frame.frame_id - self._last_complete_id) & 0xFFFFFFFF
            if 0 < distance < 0x80000000:
                self.stats["complete_id_gap"] += distance - 1
            elif distance:
                self.stats["out_of_order_complete"] += 1
        if self._last_complete_id is None or frame_is_newer(frame.frame_id, self._last_complete_id):
            self._last_complete_id = frame.frame_id
        return group


def encode_entries(transaction: int, code: int, entries: list[tuple[int, int]]) -> bytes:
    if len(entries) > 32 or len(set(reg for reg, _ in entries)) != len(entries):
        raise ValueError("at most 32 distinct registers")
    return struct.pack("<HBB", transaction, code, len(entries)) + b"".join(struct.pack("<HI", reg, value) for reg, value in entries)


def decode_entries(payload: bytes) -> tuple[int, int, list[tuple[int, int]]]:
    if len(payload) < 4:
        raise ValueError("command header truncated")
    txn, code, count = struct.unpack_from("<HBB", payload)
    if count > 32 or len(payload) != 4 + 6 * count:
        raise ValueError("command entry length invalid")
    entries = [struct.unpack_from("<HI", payload, 4 + 6 * i) for i in range(count)]
    if len(set(reg for reg, _ in entries)) != count:
        raise ValueError("duplicate register")
    return txn, code, entries


class RegisterBank:
    """Behavioral control model; hardware commits must use the same atomic boundary."""

    def __init__(self, fft_size: int = 512, fir_taps: int = 31, data_width: int = 16):
        self.spec = {reg["address"]: reg for reg in C.REGISTERS}
        self.values = {reg["address"]: reg["default"] for reg in C.REGISTERS}
        self.values.update({257: fft_size, 258: fir_taps, 259: data_width})
        self.epoch = 0
        self.pending: tuple[int, dict[int, int], list[int]] | None = None

    def handle(self, frame: Frame) -> Frame | None:
        txn = struct.unpack_from("<H", frame.payload)[0] if len(frame.payload) >= 2 else 0
        try:
            txn, opcode, entries = decode_entries(frame.payload)
        except ValueError:
            return self._response(txn, C.ERR_BAD_COMMAND, [])
        if opcode == C.CMD_INFO and not entries:
            return self._response(txn, C.ERR_OK, sorted(self.values.items()))
        if opcode not in (C.CMD_READ, C.CMD_WRITE):
            return self._response(txn, C.ERR_BAD_COMMAND, [])
        if any(reg not in self.spec for reg, _ in entries):
            return self._response(txn, C.ERR_BAD_REGISTER, [])
        if opcode == C.CMD_READ:
            return self._response(txn, C.ERR_OK, [(reg, self.values[reg]) for reg, _ in entries])
        if self.pending is not None:
            return self._response(txn, C.ERR_BUSY, [])
        candidate = self.values.copy()
        for reg, value in entries:
            spec = self.spec[reg]
            if spec["access"] != "rw":
                return self._response(txn, C.ERR_READ_ONLY, [])
            if ("allowed" in spec and value not in spec["allowed"]) or ("min" in spec and not spec["min"] <= value <= spec["max"]):
                return self._response(txn, C.ERR_BAD_VALUE, [])
            candidate[reg] = value
        if candidate[17] + (candidate[19] if candidate[1] == 2 else 0) > 32767:
            return self._response(txn, C.ERR_BAD_VALUE, [])
        self.pending = txn, candidate, [reg for reg, _ in entries]
        return None

    def commit_boundary(self) -> Frame | None:
        if self.pending is None:
            return None
        txn, candidate, addresses = self.pending
        self.pending = None
        if candidate != self.values:
            self.epoch = (self.epoch + 1) & 0xFFFF
        self.values = candidate
        return self._response(txn, C.ERR_OK, [(reg, self.values[reg]) for reg in addresses])

    def _response(self, txn: int, code: int, entries: list[tuple[int, int]]) -> Frame:
        return Frame(C.TYPE_RESPONSE, 0, self.epoch, encode_entries(txn, code, entries))
