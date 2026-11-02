"""Reason counters preserve rejection behavior; bounded optional evidence."""
import pytest
from migration.touch_v1.ethernet.host.protocol import Assembler, Packet, Kind, PACKETS


def wire(frame, index=0, epoch=0, value=0):
    return Packet(Kind.IMAGE, 7, frame, frame + 100, epoch, index, bytes([value]) * 1440).encode()


@pytest.mark.parametrize('reason', ['timeout', 'capacity', 'metadata', 'conflicting_duplicate', 'superseded'])
def test_drop_reason_and_missing_indices(reason):
    a = Assembler(7, diagnostic_limit=4)
    a.add(wire(1, 0), 0)
    a.add(wire(1, 2), .01)
    if reason == 'timeout':
        a.expire(.21)
    elif reason == 'capacity':
        for fid in (2, 3, 4):
            a.add(wire(fid), .02)
    elif reason == 'metadata':
        a.add(wire(1, 3, epoch=2), .02)
    elif reason == 'conflicting_duplicate':
        a.add(wire(1, 2, value=1), .02)
    else:
        for index in range(PACKETS):
            a.add(wire(2, index), .02)
    assert a.stats['dropped'] == a.stats['dropped_' + reason] == 1
    assert sum(v for k, v in a.stats.items() if k.startswith('dropped_')) == 1
    event = a.drop_events[0]
    assert event['reason'] == reason
    assert event['unique_packets'] == 2
    assert event['missing_packets'] == PACKETS - 2
    assert event['missing_ranges_inclusive'] == [[1, 1], [3, 1279]]
    assert event['source_frame'] == 101 and event['epoch'] == 0
    assert a.add(wire(1, 1), .22) is None  # rejected frame cannot resurrect


def test_evidence_is_opt_in_bounded_and_pending_is_not_a_drop():
    normal = Assembler(7)
    normal.add(wire(1), 0)
    normal.expire(.2)
    assert normal.stats['dropped_timeout'] == 1 and normal.drop_events == []
    diagnosed = Assembler(7, diagnostic_limit=2)
    for frame in range(8):
        diagnosed.add(wire(frame), frame)
        diagnosed.expire(frame + .3)
    assert diagnosed.stats['dropped'] == 8 and len(diagnosed.drop_events) == 2
    diagnosed.add(wire(20, 1279), 20)
    pending = diagnosed.describe_pending(20, diagnosed.pending[20], 20.01)
    assert pending['missing_ranges_inclusive'] == [[0, 1278]]
    assert diagnosed.stats['dropped'] == 8
    with pytest.raises(ValueError):
        Assembler(7, diagnostic_limit=257)


@pytest.mark.parametrize('incomplete_count', [11, 13])
def test_observed_initial_holes_explain_capacity_then_superseded(incomplete_count):
    # Reconstruct observed socket-level arrival pattern, not physical loss cause.
    a = Assembler(7, diagnostic_limit=64)
    for frame in range(incomplete_count + 1):
        for index in range(PACKETS):
            if frame < incomplete_count and 26 <= index <= 50:
                continue
            a.add(wire(frame, index), frame * .034 + index * .00001)
    assert a.stats['complete'] == 1
    assert a.stats['dropped'] == incomplete_count
    assert a.stats['dropped_capacity'] == incomplete_count - 2
    assert a.stats['dropped_superseded'] == 2
    assert a.stats['dropped_timeout'] == 0
    assert a.stats['frame_gaps'] == 0
    assert all(e['missing_ranges_inclusive'] == [[26, 50]] for e in a.drop_events)
