"""Exact transaction evidence: synthetic packets only, never network I/O."""
from dataclasses import FrozenInstanceError
import pytest
from tests.test_control_session import ready, command, accept, defaults, response

def test_receipt_is_exact_immutable_and_not_relabelled_by_info():
    s=ready();s.edit({17:900});p,_,_=command(s.tick(.1))
    assert s.write_receipt is None
    assert not s.receive(response(8,p.frame,{17:900},1),.105)
    assert s.write_receipt is None
    accept(s,{17:900},.11,epoch=1)
    r=s.write_receipt
    assert (r.session,r.sequence,r.intent,r.epoch,r.received_at)==(7,p.frame,((17,900),),1,.11)
    with pytest.raises(FrozenInstanceError):r.sequence=99
    s.tick(.12);accept(s,defaults(**{'17':900}),.13,epoch=1)
    assert s.write_receipt is r and s.actual_sequence>r.sequence
    s.tick(.64);accept(s,defaults(**{'17':777}),.65,epoch=2)
    assert s.write_receipt is r and s.epoch!=r.epoch
    s.edit({17:800});s.tick(.76)
    assert s.write_receipt is None
    s.tick(1.77);accept(s,defaults(**{'17':800}),1.78,epoch=3)
    assert s.result=='UNKNOWN' and s.write_receipt is None

def test_new_session_cannot_inherit_receipt():
    s=ready();s.edit({17:900});s.tick(.1);accept(s,{17:900},.11,epoch=1)
    assert s.write_receipt is not None
    s.start_session(8,.2)
    assert s.write_receipt is None

@pytest.mark.parametrize('status,echo',[(1,{}),(0,{17:901})])
def test_rejected_or_mismatched_ack_produces_no_receipt(status,echo):
    s=ready();s.edit({17:900});s.tick(.1)
    accept(s,echo,.11,epoch=1,status=status)
    assert s.write_receipt is None
