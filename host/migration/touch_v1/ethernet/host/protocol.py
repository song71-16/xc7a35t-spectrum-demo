"""RGE1 v1: bounded full-frame RGB888 datagrams and command envelopes."""
from __future__ import annotations

from collections import Counter, OrderedDict
from dataclasses import dataclass
from enum import IntEnum
import struct
import time

from pc.proto import frame_is_newer

WIDTH, HEIGHT = 1024, 600
PIXEL_BYTES, PACKETS = 1440, 1280
HEADER = struct.Struct("!4sBBHIIIHHHHHH")
MAGIC, VERSION = b"RGE1", 1
IMAGE_PORT, CONTROL_PORT = 50000, 50001


class Kind(IntEnum):
    IMAGE = 1
    HELLO = 2
    HELLO_ACK = 3
    HEARTBEAT = 4
    STREAM = 5
    COMMAND = 6
    RESPONSE = 7
    ERROR = 8


@dataclass(frozen=True)
class Packet:
    kind: Kind
    session: int
    frame: int = 0
    source_frame: int = 0
    epoch: int = 0
    index: int = 0
    payload: bytes = b""

    def encode(self) -> bytes:
        image = self.kind == Kind.IMAGE
        limit = PIXEL_BYTES if image else 512
        if not 0 < self.session <= 0xFFFFFFFF:
            raise ValueError("session must be nonzero u32")
        if len(self.payload) > limit or (image and len(self.payload) != limit):
            raise ValueError("invalid payload length")
        if not 0 <= self.index < (PACKETS if image else 1):
            raise ValueError("invalid packet index")
        return HEADER.pack(MAGIC, VERSION, self.kind, HEADER.size, self.session,
                           self.frame, self.source_frame, self.epoch, self.index,
                           PACKETS if image else 1, len(self.payload), WIDTH, HEIGHT) + self.payload

    @classmethod
    def decode(cls, data: bytes) -> "Packet":
        if len(data) < HEADER.size:
            raise ValueError("short header")
        magic, version, kind, size, session, frame, source, epoch, index, count, length, width, height = HEADER.unpack_from(data)
        kind = Kind(kind)
        if (magic, version, size, width, height) != (MAGIC, VERSION, HEADER.size, WIDTH, HEIGHT):
            raise ValueError("unsupported header")
        if len(data) != size + length or not session:
            raise ValueError("invalid length/session")
        if kind == Kind.IMAGE:
            if length != PIXEL_BYTES or count != PACKETS or index >= PACKETS:
                raise ValueError("invalid image geometry")
        elif count != 1 or index != 0 or length > 512:
            raise ValueError("invalid control geometry")
        return cls(kind, session, frame, source, epoch, index, data[size:])


@dataclass
class Image:
    frame: int
    source_frame: int
    epoch: int
    rgb: bytearray


class Assembler:
    """Latest complete frame, never patch missing pixels with an older image."""

    def __init__(self, session: int, timeout: float = .2, capacity: int = 3,
                 diagnostic_limit: int = 0):
        if not 1 <= capacity <= 3 or timeout <= 0:
            raise ValueError("invalid frame window")
        if not 0 <= diagnostic_limit <= 256:
            raise ValueError("diagnostic_limit must be between 0 and 256")
        self.session, self.timeout, self.capacity = session, timeout, capacity
        self.pending: OrderedDict[int, list] = OrderedDict()
        self.last: int | None = None
        self.stats = Counter()
        self.rejected: OrderedDict[int, None] = OrderedDict()
        # Optional bounded evidence; normal display incurs no bitmap scan/copy.
        self.diagnostic_limit = diagnostic_limit
        self.drop_events: list[dict] = []

    @staticmethod
    def describe_pending(frame: int, item: list, now: float) -> dict:
        image, seen = item[1], item[2]
        ranges = []
        for index, present in enumerate(seen):
            if not present:
                if ranges and ranges[-1][1] == index - 1:
                    ranges[-1][1] = index
                else:
                    ranges.append([index, index])
        return dict(frame=frame, source_frame=image.source_frame, epoch=image.epoch,
                    age_seconds=max(0, now - item[0]), unique_packets=item[3],
                    missing_packets=PACKETS - item[3], missing_ranges_inclusive=ranges)

    def _reject(self, frame: int, reason: str, now: float):
        item = self.pending.pop(frame, None)
        if item is not None and len(self.drop_events) < self.diagnostic_limit:
            self.drop_events.append(dict(reason=reason,
                **self.describe_pending(frame, item, now)))
        self.rejected[frame] = None
        while len(self.rejected) > 64:
            self.rejected.popitem(last=False)
        self.stats["dropped"] += 1
        self.stats[f"dropped_{reason}"] += 1

    def expire(self, now: float):
        for frame, item in list(self.pending.items()):
            if now - item[0] >= self.timeout:
                self._reject(frame, 'timeout', now)

    def add(self, data: bytes, now: float | None = None) -> Image | None:
        now = time.monotonic() if now is None else now
        self.expire(now)
        try:
            p = Packet.decode(data)
        except ValueError:
            self.stats["invalid"] += 1
            return None
        if p.kind != Kind.IMAGE or p.session != self.session:
            self.stats["foreign"] += 1
            return None
        if p.frame in self.rejected or (self.last is not None and not frame_is_newer(p.frame, self.last)):
            self.stats["stale"] += 1
            return None
        if p.frame not in self.pending:
            if len(self.pending) == self.capacity:
                self._reject(next(iter(self.pending)), 'capacity', now)
            self.pending[p.frame] = [now, Image(p.frame, p.source_frame, p.epoch, bytearray(WIDTH * HEIGHT * 3)), bytearray(PACKETS), 0]
        item = self.pending[p.frame]
        image, seen = item[1], item[2]
        if (image.source_frame, image.epoch) != (p.source_frame, p.epoch):
            self.stats["metadata_error"] += 1
            self._reject(p.frame, 'metadata', now)
            return None
        start = p.index * PIXEL_BYTES
        if seen[p.index]:
            if image.rgb[start:start + PIXEL_BYTES] != p.payload:
                self.stats["conflicting_duplicate"] += 1
                self._reject(p.frame, 'conflicting_duplicate', now)
            else:
                self.stats["duplicate"] += 1
            return None
        image.rgb[start:start + PIXEL_BYTES] = p.payload
        seen[p.index] = 1
        item[3] += 1
        if item[3] != PACKETS:
            return None
        self.pending.pop(p.frame)
        if self.last is not None:
            self.stats['frame_gaps'] += ((p.frame - self.last) & 0xFFFFFFFF) - 1
        self.last = p.frame
        self.stats["complete"] += 1
        for frame in list(self.pending):
            if not frame_is_newer(frame, p.frame):
                self._reject(frame, 'superseded', now)
        return image
