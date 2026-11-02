"""Offline wire-level control scheduling scenarios; no network/socket use."""
import pytest
import struct

from pc import protocol_constants as C
from pc.proto import Frame, StreamParser, decode_entries, encode_entries
from migration.touch_v1.ethernet.host.protocol import Packet, Kind
from migration.touch_v1.demo.host.control_session import ControlSession


def defaults(**changes):
    regs = {r['address']: r['default'] for r in C.REGISTERS}
    regs.update({int(k): v for k, v in changes.items()})
    return regs


def command(wire):
    p = Packet.decode(wire)
    frames = StreamParser().feed(p.payload, 0)
    assert len(frames) == 1 and frames[0].type == C.TYPE_COMMAND
    txn, opcode, entries = decode_entries(frames[0].payload)
    assert txn == (p.frame & 0xffff)
    return p, opcode, dict(entries)


def response(session, sequence, regs, epoch=0, status=0):
    payload = Frame(C.TYPE_RESPONSE, 0, epoch,
                    encode_entries(sequence & 0xffff, status, sorted(regs.items()))).encode()
    return Packet(Kind.RESPONSE, session, sequence, payload=payload)


def accept(s, regs, now, epoch=0, status=0):
    assert s.receive(response(s.commands.session, s.commands.sequence, regs, epoch, status), now)


def ready():
    s = ControlSession()
    s.start_session(7, 0)
    _, opcode, values = command(s.tick(0))
    assert opcode == C.CMD_INFO and values == {}
    accept(s, defaults(), .01)
    assert s.ready
    return s


def test_initial_read_requires_complete_legal_state():
    s = ControlSession();s.start_session(7, 0)
    with pytest.raises(RuntimeError):s.edit({17: 5})
    s.tick(0);accept(s, {16: 100, 17: 200}, .01)
    assert not s.ready and not s.actual
    _, op, entries = command(s.tick(.02));assert op == C.CMD_INFO and not entries
    accept(s, defaults(**{'256': 0}), .03)
    assert not s.ready
    s.tick(.04);accept(s, defaults(), .05)
    assert s.ready and s.actual[256] == 100000000


def test_dirty_fields_coalesce_without_cached_values_or_early_success():
    s = ready()
    s.edit({16: 123});s.edit({17: 200});s.edit({17: 300})
    assert len(s.queued) == 2
    p, op, entries = command(s.tick(.1))
    assert op == C.CMD_WRITE and entries == {16: 123, 17: 300}
    assert s.result == 'PENDING' and s.actual == defaults()
    assert s.tick(.2) is None
    accept(s, entries, .21, epoch=1)
    assert s.result == 'APPLIED' and not s.ready and s.actual == defaults()
    _, op, entries = command(s.tick(.22));assert op == C.CMD_INFO and not entries
    accept(s, defaults(**{'16': 123, '17': 300}), .23, epoch=1)
    assert s.ready and s.actual[16] == 123 and s.actual[17] == 300


def test_local_frequency_change_is_not_overwritten_by_pc_amplitude_edit():
    s = ready();s.edit({17: 900})
    _, op, entries = command(s.tick(.1))
    assert op == C.CMD_WRITE and entries == {17: 900}
    # The FPGA may have applied a local frequency change before this WRITE.
    accept(s, entries, .11, epoch=2)
    s.tick(.12);accept(s, defaults(**{'16': 999999, '17': 900}), .13, epoch=2)
    assert s.actual[16] == 999999 and not s.queued
    assert s.tick(.2) is None


def test_write_timeout_queries_without_retry_and_ignores_late_ack():
    s = ready();s.edit({17: 900});p, _, _ = command(s.tick(.1))
    s.edit({16: 123})
    q, op, entries = command(s.tick(1.11))
    assert op == C.CMD_INFO and not entries and q.frame > p.frame
    assert s.result == 'UNKNOWN' and not s.queued and not s.ready
    assert not s.receive(response(7, p.frame, {17: 900}, 1), 1.12)
    accept(s, defaults(**{'17': 777}), 1.13, epoch=2)
    assert s.ready and s.actual[17] == 777 and s.result == 'UNKNOWN'
    assert s.tick(1.2) is None  # old write and coalesced draft never replay
    assert not s.receive(response(7, 1, defaults(), 0), 1.21)
    assert s.actual[17] == 777


def test_deadline_is_checked_before_accept_even_without_tick():
    s = ready();s.edit({17: 900});p, _, _ = command(s.tick(.1))
    assert not s.receive(response(7, p.frame, {17: 900}), 1.11)
    assert command(s.tick(1.12))[1] == C.CMD_INFO
    assert s.result == 'UNKNOWN'


def test_periodic_read_has_priority_over_continuous_edits():
    s = ready()
    assert s.tick(.50) is None
    for value in range(100):s.edit({17: value})
    _, op, entries = command(s.tick(.52))
    assert op == C.CMD_INFO and not entries and s.queued == {17: 99}
    s.edit({17: 105});accept(s, defaults(**{'16': 111}), .53)
    _, op, entries = command(s.tick(.54))
    assert op == C.CMD_WRITE and entries == {17: 105}
    accept(s, entries, .55)
    assert command(s.tick(.56))[1] == C.CMD_INFO


def test_info_failure_bound_reconnect_and_old_session_isolation():
    s = ready();s.edit({17: 900});s.tick(.1)
    s.tick(1.11)  # WRITE timeout -> INFO
    s.tick(2.12);s.tick(3.13)
    assert s.tick(4.14) is None
    assert s.needs_reconnect and not s.online and s.result == 'UNKNOWN'
    s.start_session(8, 5)
    _, op, entries = command(s.tick(5))
    assert op == C.CMD_INFO and not entries
    assert not s.receive(response(7, 1, defaults(**{'17': 900})), 5.01)
    accept(s, defaults(**{'17': 250}), 5.02)
    assert s.ready and s.actual[17] == 250 and s.result == 'UNKNOWN'
    assert s.tick(5.03) is None


def test_disconnect_discards_drafts_and_requires_new_session_info():
    s = ready();s.edit({16: 123});s.disconnect()
    assert not s.ready and not s.queued
    with pytest.raises(ValueError):s.start_session(7, 1)
    s.start_session(8, 1)
    assert command(s.tick(1))[1:] == (C.CMD_INFO, {})
    accept(s, defaults(**{'16': 555}), 1.01)
    assert s.actual[16] == 555 and s.tick(1.1) is None


def test_sequence_exhaustion_and_epoch_wrap_use_correct_identity():
    s = ready();s.commands.sequence = 0xfffffffe
    p, op, _ = command(s.tick(.52));assert p.frame == 0xffffffff and op == C.CMD_INFO
    accept(s, defaults(**{'17': 456}), .53, epoch=0)
    assert s.actual[17] == 456
    assert s.tick(.54) is None and s.needs_reconnect and not s.online
    s.start_session(8, 1);s.tick(1);accept(s, defaults(), 1.01, epoch=65535)
    s.tick(1.52);accept(s, defaults(**{'17': 321}), 1.53, epoch=0)
    assert s.epoch == 0 and s.actual[17] == 321


@pytest.mark.parametrize('frequency', [-1, 50000000, float('nan'), float('inf')])
def test_frequency_rejects_invalid_or_unrepresentable_values(frequency):
    s = ready()
    with pytest.raises(ValueError):s.frequency_step(frequency)


def test_write_rejection_and_mismatched_ack_require_readback():
    s = ready();s.edit({17: 32767});s.tick(.1)
    accept(s, {}, .11, status=C.ERR_BAD_VALUE)
    assert s.result == 'FAILED' and not s.ready and s.actual == defaults()
    s.tick(.12);accept(s, defaults(), .13)
    s.edit({17: 900});s.tick(.21);accept(s, {17: 800}, .22)
    assert s.result == 'UNKNOWN' and not s.ready
    assert command(s.tick(.23))[1] == C.CMD_INFO


def test_write_limit_and_inflight_new_intent_survive_ack_readback():
    s = ready();s.edit({17: 900});s.tick(.1)
    s.edit({16: 123});s.edit({17: 1000})
    accept(s, {17: 900}, .11)
    s.tick(.12);accept(s, defaults(**{'16': 555, '17': 900}), .13)
    assert s.actual[16] == 555 and s.queued == {16: 123, 17: 1000}
    assert s.tick(.199) is None
    _, op, entries = command(s.tick(.2))
    assert op == C.CMD_WRITE and entries == {16: 123, 17: 1000}


def test_info_failure_drops_coalesced_intent():
    s = ready();s.edit({17: 900});s.tick(.1);s.edit({16: 123})
    accept(s, {17: 900}, .11);s.tick(.12)
    accept(s, {}, .13, status=C.ERR_BUSY)
    assert not s.ready and not s.queued
    s.tick(.14);accept(s, defaults(**{'16': 555, '17': 900}), .15)
    assert s.ready and s.tick(.2) is None


def test_malformed_duplicate_and_wrong_transaction_keep_pending():
    s = ready();p, _, _ = command(s.tick(.52))
    pending = s.commands.pending
    assert not s.receive(Packet(Kind.RESPONSE, 7, p.frame, payload=b'broken'), .53)
    wrong = Frame(C.TYPE_RESPONSE, 0, 0, encode_entries(999, 0, list(defaults().items()))).encode()
    assert not s.receive(Packet(Kind.RESPONSE, 7, p.frame, payload=wrong), .54)
    entries = list(defaults().items()) + [(17, 123)]
    raw = struct.pack('<HBB', p.frame & 0xffff, 0, len(entries))
    raw += b''.join(struct.pack('<HI', *entry) for entry in entries)
    duplicate = Frame(C.TYPE_RESPONSE, 0, 0, raw).encode()
    assert not s.receive(Packet(Kind.RESPONSE, 7, p.frame, payload=duplicate), .55)
    assert s.commands.pending is pending and s.actual == defaults()
    accept(s, defaults(**{'17': 123}), .56)
    assert s.commands.pending is None and s.actual[17] == 123
