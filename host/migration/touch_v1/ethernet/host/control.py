"""Retry the identical datagram; a timeout means unknown outcome, not rollback."""
from __future__ import annotations
from dataclasses import dataclass
from pc import protocol_constants as C
from pc.proto import Frame, StreamParser, encode_entries, decode_entries
from .protocol import Packet, Kind


@dataclass
class Pending:
    sequence: int
    transaction: int
    wire: bytes
    sent: float
    attempts: int = 1


class Commands:
    def __init__(self, session: int):
        self.session = session
        self.sequence = 0
        self.pending: Pending | None = None
        self.epoch = 0

    def request(self, opcode: int, entries: list[tuple[int, int]], now: float) -> bytes:
        if self.pending:
            raise RuntimeError("a command is already outstanding")
        if self.sequence == 0xFFFFFFFF:
            raise RuntimeError("reconnect before sequence wrap")
        self.sequence += 1
        transaction = self.sequence & 0xFFFF
        payload = Frame(C.TYPE_COMMAND, 0, self.epoch, encode_entries(transaction, opcode, entries)).encode()
        wire = Packet(Kind.COMMAND, self.session, self.sequence, payload=payload).encode()
        self.pending = Pending(self.sequence, transaction, wire, now)
        return wire

    def poll(self, now: float) -> bytes | None:
        p = self.pending
        if p and now - p.sent >= 1:
            if p.attempts >= 3:
                self.pending = None
                raise TimeoutError("command outcome unknown; reconnect and read configuration")
            p.attempts += 1
            p.sent = now
            return p.wire
        return None

    def accept(self, packet: Packet) -> tuple[int, dict[int, int]] | None:
        p = self.pending
        if (not p or packet.kind != Kind.RESPONSE or packet.session != self.session
                or packet.frame != p.sequence):
            return None
        parser = StreamParser()
        frames = parser.feed(packet.payload, 0)
        if len(frames) != 1 or parser.buffer or parser.stats["discarded_bytes"]:
            raise ValueError("invalid response framing")
        frame = frames[0]
        if frame.type != C.TYPE_RESPONSE or frame.encode() != packet.payload:
            raise ValueError("invalid response type/encoding")
        txn, status, entries = decode_entries(frame.payload)
        if txn != p.transaction:
            return None
        self.pending = None
        if status == C.ERR_OK:
            self.epoch = frame.config_epoch
        return status, dict(entries)
