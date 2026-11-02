import random
import struct
import pytest
from pc.proto import Frame, encode_entries
from pc import protocol_constants as C
from migration.touch_v1.ethernet.host.protocol import Packet, Kind, Assembler, WIDTH, HEIGHT, PACKETS, PIXEL_BYTES
from migration.touch_v1.ethernet.host.control import Commands


def packets(frame=1, session=7, epoch=2):
    # Independent full image: each pixel's RGB depends on x/y and frame.
    rgb = bytes(v for y in range(HEIGHT) for x in range(WIDTH)
                for v in ((x + frame) & 255, y & 255, (x ^ y ^ frame) & 255))
    return rgb, [Packet(Kind.IMAGE, session, frame, (frame + 100) & 0xFFFFFFFF, epoch, i,
                         rgb[i * PIXEL_BYTES:(i + 1) * PIXEL_BYTES]).encode() for i in range(PACKETS)]


def test_two_full_frames_reordered_and_duplicates():
    assembler = Assembler(7)
    count = 0
    for fid in (1, 2):
        rgb, wire = packets(fid)
        wire += wire[:30]
        random.Random(71 + fid).shuffle(wire)
        images = [image for i, data in enumerate(wire) if (image := assembler.add(data, fid + i * .00001))]
        assert len(images) == 1
        assert images[0].rgb == rgb
        assert (images[0].source_frame, images[0].epoch) == (fid + 100, 2)
        count += len(rgb) // 3
    assert count == 1_228_800


def test_loss_timeout_no_resurrection():
    _, wire = packets()
    a = Assembler(7)
    for data in wire[:-1]:
        assert a.add(data, 0) is None
    a.expire(.2)
    assert a.add(wire[-1], .21) is None
    assert not a.pending and a.stats['dropped'] == 1


def test_bounded_foreign_metadata_and_conflicting_duplicate():
    a = Assembler(7)
    for fid in range(4):
        a.add(Packet(Kind.IMAGE, 7, fid, payload=bytes(1440)).encode(), fid * .01)
    assert len(a.pending) == 3 and a.stats['dropped'] == 1
    assert a.add(Packet(Kind.IMAGE, 8, 8, payload=bytes(1440)).encode(), .05) is None
    a.add(Packet(Kind.IMAGE, 7, 3, payload=b'x' * 1440).encode(), .06)
    assert a.stats['conflicting_duplicate'] == 1 and 3 not in a.pending
    a.add(Packet(Kind.IMAGE, 7, 2, epoch=9, index=1, payload=bytes(1440)).encode(), .07)
    assert a.stats['metadata_error'] == 1


@pytest.mark.parametrize('offset,value', [(0, 0), (4, 2), (5, 99), (7, 31), (25, 1), (27, 1), (31, 0)])
def test_bad_headers(offset, value):
    wire = bytearray(Packet(Kind.IMAGE, 7, payload=bytes(1440)).encode())
    wire[offset] = value
    with pytest.raises(ValueError):
        Packet.decode(wire)


def test_retry_identity_timeout_and_response():
    c = Commands(7)
    wire = c.request(C.CMD_WRITE, [(0, 0)], 0)
    assert c.poll(.9) is None
    assert c.poll(1) == c.poll(2) == wire
    with pytest.raises(TimeoutError):
        c.poll(3)
    wire = c.request(C.CMD_INFO, [], 4)
    response = Frame(C.TYPE_RESPONSE, 0, 6, encode_entries(2, 0, [(0, 0)])).encode()
    assert c.accept(Packet(Kind.RESPONSE, 8, 2, payload=response)) is None
    assert c.accept(Packet(Kind.RESPONSE, 7, 1, payload=response)) is None
    assert c.accept(Packet(Kind.RESPONSE, 7, 2, payload=response)) == (0, {0: 0})
    assert c.epoch == 6 and c.pending is None


def test_entire_missing_frame_is_counted_and_wrap_is_ordered():
    a = Assembler(7)
    for fid in (0xFFFFFFFE, 0):
        rgb, wire = packets(fid)
        # source_frame is a separate uint32 field, so use an in-range fixture.
        for i in range(PACKETS):
            data = Packet(Kind.IMAGE, 7, fid, 7, 2, i, rgb[i*PIXEL_BYTES:(i+1)*PIXEL_BYTES]).encode()
            result = a.add(data, 0)
        assert result is not None
    assert a.stats['frame_gaps'] == 1
