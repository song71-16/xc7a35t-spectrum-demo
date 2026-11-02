"""Real worker and Qt integration with synthetic I/O only; no OS socket creation."""
from collections import deque
import errno
import os
from pathlib import Path
import queue
import threading

import pytest
from pc import protocol_constants as C
from pc.proto import Frame, StreamParser, decode_entries, encode_entries
from migration.touch_v1.ethernet.host.protocol import Packet, Kind, Image, IMAGE_PORT, CONTROL_PORT, PACKETS
from migration.touch_v1.demo.host.transport import Receiver


def defaults():return {r['address']:r['default'] for r in C.REGISTERS}


class FakeSocket:
    def __init__(self, network):self.network=network;self.incoming=deque();self.closed=False;self.port=None
    def setsockopt(self,*args):pass
    def ioctl(self,*args):pass
    def bind(self,address):self.port=address[1];self.network.sockets[self.port]=self
    def setblocking(self,value):assert value is False
    def sendto(self,wire,address):self.network.sent(Packet.decode(wire),address)
    def recvfrom(self,size):
        if not self.incoming:raise BlockingIOError()
        return self.incoming.popleft()
    def close(self):self.closed=True


class Network:
    def __init__(self, *, drop_write=False, fail_write_send=False, drop_info=False, images=False):
        self.now=0.;self.sockets={};self.history=[];self.events=[];self.state={}
        self.regs=defaults();self.epoch=0;self.session=0;self.generation=6
        self.drop_write=drop_write;self.fail_write_send=fail_write_send;self.drop_info=drop_info
        self.images=images;self.image_sessions=set();self.applied=0;self.worker=None
        self.steps=0;self.timed_out=False;self.hook=lambda n:None;self.silence=False
        self.info_status=0
    def clock(self):return self.now
    def sleep(self,seconds):self.now+=seconds
    def new_session(self):self.generation+=1;return self.generation
    def socket(self,*args):return FakeSocket(self)
    def inject(self,packet,port=CONTROL_PORT):
        self.sockets[port].incoming.append((packet.encode(),('board',port)))
    def sent(self,p,address):
        assert address==('board',CONTROL_PORT)
        self.history.append((self.now,p))
        if self.silence:return
        if p.kind==Kind.HELLO:
            self.session=p.session;self.inject(Packet(Kind.HELLO_ACK,p.session,payload=b'\x01'))
        elif p.kind==Kind.HEARTBEAT:self.inject(Packet(Kind.HEARTBEAT,p.session,payload=p.payload))
        elif p.kind==Kind.STREAM and p.payload==b'\x01' and self.images and p.session not in self.image_sessions:
            self.image_sessions.add(p.session);self.inject_image(p.session,p.session)
        elif p.kind==Kind.COMMAND:
            frame=StreamParser().feed(p.payload,0)[0];txn,op,entries=decode_entries(frame.payload)
            if op==C.CMD_WRITE:
                self.applied+=1;self.regs.update(entries);self.epoch+=1
                if self.fail_write_send:raise OSError(errno.ENETUNREACH,'synthetic send uncertainty')
                if self.drop_write:return
                regs=entries
            else:
                assert op==C.CMD_INFO
                if self.drop_info:return
                regs=sorted(self.regs.items())
            status=self.info_status if op==C.CMD_INFO else 0
            wire=Frame(C.TYPE_RESPONSE,0,self.epoch,encode_entries(txn,status,regs)).encode()
            self.inject(Packet(Kind.RESPONSE,p.session,p.frame,payload=wire))
    def inject_image(self,session,frame):
        for i in range(PACKETS):
            self.inject(Packet(Kind.IMAGE,session,frame,100+frame,self.epoch,i,bytes([frame%256])*1440),IMAGE_PORT)
    def select(self,sockets,*args):
        self.now+=.01;self.steps+=1
        for _ in range(32):
            try:event=self.worker.events.get_nowait()
            except queue.Empty:break
            self.events.append(event)
            if event[0]=='state':self.state=event[2]
        self.hook(self)
        if self.steps>1400:self.timed_out=True;self.worker.stop_event.set()
        return [s for s in sockets if s.incoming],[],[]
    def run(self,hook):
        self.hook=hook
        self.worker=Receiver('host','board',clock=self.clock,socket_factory=self.socket,
                             selector=self.select,session_factory=self.new_session,sleeper=self.sleep)
        self.worker.run()
        assert not self.timed_out and not self.worker.last_error
        assert len(self.sockets)==2 and all(s.closed for s in self.sockets.values())
        assert not self.worker.connected and not self.worker.ready


def command_ops(n):
    return [(p.session,p.frame,decode_entries(StreamParser().feed(p.payload,0)[0].payload)[1])
            for _,p in n.history if p.kind==Kind.COMMAND]


def test_worker_single_frame_peer_spacing_and_one_write():
    class SingleFramePeer(Network):
        def __init__(self):
            super().__init__();self.busy_until=0.;self.dropped=[]
        def sent(self,p,address):
            if self.now < self.busy_until:
                self.dropped.append(p);return
            self.busy_until=self.now+.002
            super().sent(p,address)
    n=SingleFramePeer();submitted=False
    def hook(n):
        nonlocal submitted
        if n.state.get('ready') and not submitted:
            assert n.worker.submit_edits(n.worker.token,{17:12288});submitted=True
        if n.now>2.1 and n.state.get('ready') and n.state['actual'][17]==12288:
            n.worker.stop_event.set()
    n.run(hook)
    assert not n.dropped and n.applied==1
    assert all(b[0]-a[0]>=.005-1e-9 for a,b in zip(n.history,n.history[1:]))
    assert sum(op==C.CMD_WRITE for _,_,op in command_ops(n))==1
    assert not any(kind=='state' and value['result']=='UNKNOWN' for kind,_,value in n.events)


def test_worker_stop_during_send_gap_does_not_dispatch_command():
    class StopDuringGap(Network):
        def sleep(self,seconds):
            self.worker.stop_event.set();super().sleep(seconds)
    n=StopDuringGap();n.run(lambda n:None)
    assert not command_ops(n)
    assert n.history[-1][1].kind==Kind.STREAM and n.history[-1][1].payload==b'\x00'
    assert all(b[0]-a[0]>=.005-1e-9 for a,b in zip(n.history,n.history[1:]))


@pytest.mark.parametrize('uncertain_send',[False,True])
def test_worker_write_once_timeout_readback_and_initial_stream_order(uncertain_send):
    n=Network(drop_write=True,fail_write_send=uncertain_send);submitted=False
    def hook(n):
        nonlocal submitted
        if n.state.get('ready') and not submitted:
            assert n.worker.submit_edits(n.worker.token,{17:900});submitted=True
        if n.state.get('result')=='UNKNOWN' and n.state.get('ready'):
            assert n.state['actual'][17]==900;n.worker.stop_event.set()
    n.run(hook)
    ops=command_ops(n)
    assert [op for _,_,op in ops].count(C.CMD_WRITE)==1 and n.applied==1
    assert ops[0][2]==C.CMD_INFO and ops[-1][2]==C.CMD_INFO
    kinds=[p.kind for _,p in n.history]
    assert kinds.index(Kind.HELLO)<kinds.index(Kind.COMMAND)<kinds.index(Kind.STREAM)
    assert sum(p.kind==Kind.STREAM and p.payload==b'\x01' for _,p in n.history)==1
    assert n.history[-1][1].kind==Kind.STREAM and n.history[-1][1].payload==b'\x00'


def test_worker_info_failure_renews_session_without_write():
    n=Network(drop_info=True)
    def hook(n):
        if n.worker.token[0]==2 and any(session==8 for session,_,_ in command_ops(n)):
            n.worker.stop_event.set()
    n.run(hook)
    ops=command_ops(n)
    assert len([x for x in ops if x[0]==7])==3
    assert all(x[2]==C.CMD_INFO for x in ops) and ops[-1][0]==8
    assert not any(p.kind==Kind.STREAM and p.payload==b'\x01' for _,p in n.history)


def test_worker_readiness_change_rejects_exact_merged_fields():
    n=Network();submitted=False;rejected=None
    def hook(n):
        nonlocal submitted,rejected
        if n.state.get('ready'):n.info_status=C.ERR_BUSY
        if n.state.get('ready') and n.state.get('in_flight')==C.CMD_INFO and not submitted:
            assert n.worker.submit_edits(n.worker.token,{16:123})
            assert n.worker.submit_edits(n.worker.token,{17:456})
            submitted=True
        for kind,token,value in n.events:
            if kind=='edit_rejected':
                rejected=value;n.worker.stop_event.set()
    n.run(hook)
    assert submitted and rejected['values']=={16:123,17:456} and n.applied==0


def test_worker_reconnect_rejects_old_intent_and_image():
    n=Network(images=True);stage=0;old_token=None
    def hook(n):
        nonlocal stage,old_token
        if stage==0 and n.worker.latest is not None:
            old_token=n.worker.token;n.silence=True;stage=1
        elif stage==1 and n.worker.token[0]==2:
            assert not n.worker.submit_edits(old_token,{17:123})
            assert n.worker.latest is None
            n.silence=False;n.inject_image(old_token[1],99);stage=2
        elif stage==2 and n.worker.latest is not None:
            token,image,_=n.worker.latest
            assert token==n.worker.token and image.frame==token[1] and image.frame!=99
            n.worker.stop_event.set();stage=3
    n.run(hook)
    assert stage==3 and n.applied==0
    assert all(op==C.CMD_INFO for _,_,op in command_ops(n))


class FakeWorker:
    def __init__(self,*args):
        self.events=queue.Queue();self.lock=threading.Lock();self.stop_event=threading.Event()
        self.latest=None;self.stats={};self.connected=True;self.last_error='';self.alive=False
        self.edits=[];self.streams=[];self.joined=False
    def start(self):self.alive=True
    def is_alive(self):return self.alive
    def submit_edits(self,token,values):self.edits.append((token,dict(values)));return True
    def request_stream(self,token,enabled):self.streams.append((token,enabled));return True
    def join(self,timeout):self.joined=True;self.alive=False


@pytest.fixture(scope='module')
def qt():
    from migration.touch_v1.demo.host.app import QApplication
    app=QApplication.instance() or QApplication([])
    yield app


def ui_state(regs=None, *, ready=True, result='NONE'):
    return dict(connected=True,ready=ready,actual=regs or defaults(),actual_at=0.,
                sequence=1,epoch=0,result=result,detail='',in_flight=None,queued={},stream=True)


def test_qt_polling_draft_submit_unknown_session_image_and_cleanup(qt):
    from migration.touch_v1.demo.host.app import Window
    observed=[]
    w=Window('host','board',worker_factory=FakeWorker,clock=lambda:1.,
             image_observer=lambda metadata,rgb:observed.append((metadata,rgb)))
    worker=w.worker;w.show();qt.processEvents()
    try:
        token=(1,7);worker.events.put(('session',token,None));worker.events.put(('state',token,ui_state()))
        w.refresh();assert w.ready and not w.dirty and not worker.edits
        w.inputs[16].setValue(1234567);assert w.dirty=={16}
        regs=defaults();regs[16]=444;regs[17]=888
        worker.events.put(('state',token,ui_state(regs)));w.refresh()
        assert w.inputs[16].value()==1234567 and w.dirty=={16} and not worker.edits
        w.submit();assert len(worker.edits)==1 and set(worker.edits[0][1])=={16}
        w.inputs[17].setValue(321);w.submit()
        assert len(worker.edits)==2 and set(worker.edits[1][1])=={17}
        rejected=dict(values={16:worker.edits[0][1][16],17:321},reason='synthetic readiness change')
        worker.events.put(('edit_rejected',token,rejected));w.refresh()
        assert w.dirty=={16,17} and w.inputs[16].value()==1234567 and w.inputs[17].value()==321
        worker.events.put(('state',token,ui_state(regs,ready=False,result='UNKNOWN')));w.refresh()
        assert not w.apply.isEnabled();w.submit();assert len(worker.edits)==2
        worker.events.put(('session',(2,8),None));w.refresh();assert not w.dirty and not w.ready
        worker.events.put(('state',token,ui_state()));worker.events.put(('edit_rejected',token,rejected))
        worker.latest=(token,Image(9,99,0,bytearray(1024*600*3)),0.)
        w.refresh();assert not w.ready and w.image_metadata is None and not w.dirty
        assert observed==[]
        worker.events.put(('state',(2,8),ui_state(regs)));w.refresh()
        assert w.ready and not w.dirty and len(worker.edits)==2
        worker.latest=((2,8),Image(10,100,4,bytearray([24,44,64])*(1024*600)),.9)
        w.refresh();assert w.image_metadata[:4]==((2,8),10,100,4)
        assert len(observed)==1 and observed[0][0]==w.image_metadata
        assert isinstance(observed[0][1],bytes) and observed[0][1]==bytes([24,44,64])*(1024*600)
        w.refresh();assert len(observed)==1
        assert '采集帧 100' in w.health.text() and '图像配置版本 4' in w.health.text()
        assert '888' in w.actual.text() and not w.apply.isEnabled()
        image_path=Path(os.environ['DEMO_TEST_ARTIFACTS'])/'pc-demo-view.png'
        w.health.setText('离线界面测试夹具（合成图像） · '+w.health.text())
        qt.processEvents();w.centralWidget().layout().activate();qt.processEvents()
        from PySide6.QtCore import Qt, QRect
        available=w.actual.contentsRect()
        needed=w.actual.fontMetrics().boundingRect(
            QRect(0,0,available.width(),10000),
            Qt.TextFlag.TextWordWrap | Qt.AlignmentFlag.AlignLeft, w.actual.text())
        assert needed.height() <= available.height() and needed.width() <= available.width()
        assert '配置版本 0' in w.actual.text() and '反馈序号 1' in w.actual.text()
        assert w.grab().save(str(image_path))
    finally:
        from PySide6.QtCore import QCoreApplication, QEvent
        w.close();w.deleteLater();QCoreApplication.sendPostedEvents(None,QEvent.Type.DeferredDelete)
        qt.processEvents()
    assert worker.stop_event.is_set() and worker.joined
