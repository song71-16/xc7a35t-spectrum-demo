"""Real Receiver thread and Qt timer with locked fake I/O, never OS sockets."""
import os
import json
from pathlib import Path
import queue
import threading
import time

import pytest
from pc import protocol_constants as C
from pc.proto import Frame, StreamParser, decode_entries, encode_entries
from migration.touch_v1.ethernet.host.protocol import Packet, Kind, IMAGE_PORT, CONTROL_PORT, PACKETS
from migration.touch_v1.demo.host.transport import Receiver


class ThreadSocket:
    def __init__(self, peer):
        self.peer=peer;self.incoming=queue.Queue();self.port=None;self.closes=0
    def setsockopt(self,*args):self.peer.check_owner()
    def ioctl(self,*args):self.peer.check_owner()
    def bind(self,address):
        self.peer.check_owner();self.port=address[1]
        with self.peer.lock:self.peer.sockets[self.port]=self
    def setblocking(self,value):self.peer.check_owner();assert value is False
    def sendto(self,wire,address):self.peer.sent(Packet.decode(wire),address)
    def recvfrom(self,size):
        self.peer.check_owner()
        try:item=self.incoming.get_nowait()
        except queue.Empty:raise BlockingIOError()
        with self.peer.lock:
            self.peer.received[self.port]+=1
            if self.port==CONTROL_PORT and Packet.decode(item[0]).kind==Kind.RESPONSE:
                self.peer.responses_delivered+=1
        return item
    def close(self):
        self.peer.check_owner()
        with self.peer.lock:self.closes+=1


class ThreadPeer:
    def __init__(self):
        self.lock=threading.RLock();self.now=100.;self.session=1000
        self.owner=None;self.sockets={};self.received={IMAGE_PORT:0,CONTROL_PORT:0}
        self.responses_delivered=0;self.selected_responses=0;self.selected_images=0
        self.regs={r['address']:r['default'] for r in C.REGISTERS};self.epoch=0
        self.history=[];self.commands=[];self.pending_info=[];self.lost_acks=[]
        self.hold_info=False;self.silent=False;self.drop_next_write=False
        self.wake=threading.Event();self.pause_requested=threading.Event()
        self.paused=threading.Event();self.resume=threading.Event();self.resume.set()
        self.worker=None
    def check_owner(self):assert threading.get_ident()==self.owner
    def socket(self,*args):
        with self.lock:
            if self.owner is None:self.owner=threading.get_ident()
        self.check_owner();return ThreadSocket(self)
    def clock(self):
        with self.lock:return self.now
    def advance(self,seconds):
        assert seconds>=0
        with self.lock:self.now+=seconds
        self.wake.set()
    def next_session(self):
        self.check_owner()
        with self.lock:self.session+=1;return self.session
    def factory(self,bind,board):
        self.worker=Receiver(bind,board,clock=self.clock,socket_factory=self.socket,
                             selector=self.select,session_factory=self.next_session,sleeper=self.advance)
        return self.worker
    def inject(self,wire,port=CONTROL_PORT):
        with self.lock:s=self.sockets[port]
        s.incoming.put((wire,('board',port)));self.wake.set()
    def configure(self,**values):
        with self.lock:
            for key,value in values.items():
                assert key in ('hold_info','silent','drop_next_write');setattr(self,key,value)
        self.wake.set()
    def local_amplitude(self,value):
        with self.lock:self.regs[17]=value;self.epoch+=1
    def info_count(self):
        with self.lock:return sum(c['opcode']==C.CMD_INFO for c in self.commands)
    def writes(self):
        with self.lock:return [dict(c,values=dict(c['values'])) for c in self.commands if c['opcode']==C.CMD_WRITE]
    def pending_count(self):
        with self.lock:return len(self.pending_info)
    def completed_responses(self):
        with self.lock:return self.selected_responses
    def completed_images(self):
        with self.lock:return self.selected_images
    def release_info(self):
        with self.lock:
            pending,self.pending_info=self.pending_info,[];self.hold_info=False
        for wire in pending:self.inject(wire)
    def request_hold(self):
        self.resume.clear();self.pause_requested.set();self.wake.set()
    def release(self):
        self.pause_requested.clear();self.resume.set();self.wake.set()
    def select(self,sockets,*args):
        self.check_owner()
        # A new selector entry occurs only after the preceding receive loop and
        # its publish/assembler work have returned to the real worker loop.
        with self.lock:
            self.selected_responses=self.responses_delivered
            self.selected_images=self.received[IMAGE_PORT]
        if self.pause_requested.is_set():
            self.paused.set()
            if not self.resume.wait(3):raise TimeoutError('test selector barrier expired')
            self.paused.clear()
        self.wake.wait(.005);self.wake.clear()
        return [s for s in sockets if not s.incoming.empty()],[],[]
    def sent(self,p,address):
        self.check_owner();assert address==('board',CONTROL_PORT)
        with self.lock:
            self.history.append((self.now,threading.get_ident(),p))
            if self.silent:return
            if p.kind==Kind.HELLO:
                self.inject(Packet(Kind.HELLO_ACK,p.session,payload=b'\x01').encode())
            elif p.kind==Kind.HEARTBEAT:
                self.inject(Packet(Kind.HEARTBEAT,p.session,payload=p.payload).encode())
            elif p.kind==Kind.COMMAND:
                frame=StreamParser().feed(p.payload,0)[0];txn,opcode,entries=decode_entries(frame.payload)
                values=dict(entries)
                self.commands.append(dict(session=p.session,sequence=p.frame,opcode=opcode,values=values))
                if opcode==C.CMD_WRITE:
                    self.regs.update(values);self.epoch+=1;answer=entries
                else:
                    assert opcode==C.CMD_INFO;answer=sorted(self.regs.items())
                wire=Packet(Kind.RESPONSE,p.session,p.frame,payload=Frame(
                    C.TYPE_RESPONSE,0,self.epoch,encode_entries(txn,0,answer)).encode()).encode()
                if opcode==C.CMD_WRITE and self.drop_next_write:
                    self.drop_next_write=False;self.lost_acks.append(wire)
                elif opcode==C.CMD_INFO and self.hold_info:self.pending_info.append(wire)
                else:self.inject(wire)
    def image(self,session,frame):
        with self.lock:epoch=self.epoch
        for index in range(PACKETS):
            self.inject(Packet(Kind.IMAGE,session,frame,100+frame,epoch,index,
                               bytes([frame%256])*1440).encode(),IMAGE_PORT)
    def assert_closed(self):
        with self.lock:assert len(self.sockets)==2 and all(s.closes==1 for s in self.sockets.values())


def until(predicate,qt=None,seconds=3):
    end=time.monotonic()+seconds
    while True:
        if qt is not None:qt.processEvents()
        if predicate():return
        if time.monotonic()>=end:raise AssertionError('threaded test wall-clock deadline')
        threading.Event().wait(.002)


def evidence(name,data):
    with (Path(os.environ['DEMO_TEST_ARTIFACTS'])/name).open('x',encoding='utf-8') as f:
        json.dump(data,f,ensure_ascii=False,indent=2)


@pytest.fixture(scope='module')
def qt():
    # Import app before Qt modules so its existing Windows ICU setup is used.
    from migration.touch_v1.demo.host.app import QApplication
    app=QApplication.instance() or QApplication([])
    yield app


def test_real_thread_qt_coalesce_poll_unknown_reconnect_images_close(qt):
    from migration.touch_v1.demo.host.app import Window
    from PySide6.QtCore import QCoreApplication,QEvent
    peer=ThreadPeer();main_id=threading.get_ident();timer_ids=[]
    w=Window('host','board',worker_factory=peer.factory,clock=peer.clock);worker=peer.worker
    w.timer.timeout.connect(lambda:timer_ids.append(threading.get_ident()))
    w.show()
    try:
        until(lambda:w.ready,qt)
        assert worker.is_alive() and worker.ident==peer.owner and peer.owner!=main_id
        token=w.token
        peer.image(token[1],17);until(lambda:w.image_metadata is not None,qt)
        assert w.image_metadata[:4]==(token,17,117,0)

        peer.request_hold();until(peer.paused.is_set,qt)
        before=len(peer.writes())
        for address,value in [(16,6250000),(17,1000),(17,1500)]:
            w.inputs[address].setValue(value);until(w.apply.isEnabled,qt);w.apply.click()
        assert not w.dirty and len(peer.writes())==before
        peer.release()
        until(lambda:w.ready and w.state['actual'][17]==1500,qt)
        writes=peer.writes()
        assert len(writes)==1 and writes[0]['values']=={16:268435456,17:1500}
        assert w.state['actual'][16]==268435456 and w.state['epoch']==1

        peer.local_amplitude(4096);peer.advance(.51)
        until(lambda:w.ready and w.state['actual'][17]==4096,qt)
        assert len(peer.writes())==1 and w.inputs[17].value()==1500
        assert w.image_metadata[3]==0 and w.state['epoch']==2

        peer.configure(drop_next_write=True,hold_info=True)
        w.inputs[17].setValue(9000);until(w.apply.isEnabled,qt);w.apply.click()
        until(lambda:len(peer.writes())==2,qt)
        peer.image(token[1],18)
        until(lambda:w.image_metadata[1]==18,qt)
        peer.advance(1.01)
        until(lambda:peer.pending_count()>0 and w.state.get('result')=='UNKNOWN' and not w.ready,qt)
        assert not w.apply.isEnabled() and '此前操作结果未知' in w.message.text()
        assert w.state['actual'][17]==4096 and len(peer.writes())==2
        peer.release_info()
        until(lambda:w.ready and w.state['actual'][17]==9000,qt)
        assert w.state['result']=='UNKNOWN' and len(peer.writes())==2

        # An unsubmitted edit from the old session must not survive reconnect.
        w.inputs[17].setValue(2222);assert w.dirty=={17}
        peer.configure(silent=True,hold_info=True);peer.advance(3.01)
        until(lambda:w.token[0]==2,qt)
        assert not w.ready and not w.dirty and not w.apply.isEnabled()
        assert not worker.submit_edits(token,{17:123})
        old_metadata=w.image_metadata
        peer.local_amplitude(7777);peer.configure(silent=False);peer.advance(1.01)
        until(lambda:peer.pending_count()>0,qt)
        with peer.lock:
            old_ack=peer.lost_acks[0]
            old_image_target=peer.received[IMAGE_PORT]+PACKETS
        peer.inject(old_ack);peer.image(token[1],99)
        until(lambda:peer.completed_images()>=old_image_target,qt)
        timer_before_old_check=len(timer_ids)
        until(lambda:len(timer_ids)>timer_before_old_check,qt)
        assert not w.ready and not w.apply.isEnabled() and w.image_metadata==old_metadata
        peer.release_info()
        until(lambda:w.ready and w.state['actual'][17]==7777,qt)
        assert w.inputs[17].value()==7777 and not w.dirty and len(peer.writes())==2
        new_session=w.token[1]
        with peer.lock:new_commands=[c for c in peer.commands if c['session']==new_session]
        assert new_commands and all(c['opcode']==C.CMD_INFO for c in new_commands)
        peer.image(new_session,19);until(lambda:w.image_metadata[1]==19,qt)
        assert w.image_metadata[:4]==(w.token,19,119,4)
        pixel=w.pixmap.toImage().pixelColor(0,0)
        assert (pixel.red(),pixel.green(),pixel.blue())==(19,19,19)
        assert len(timer_ids)>5 and set(timer_ids)=={main_id}
        assert '7777' in w.actual.text() and len(peer.writes())==2
        assert all(c['session']==token[1] for c in peer.writes())
        # This snapshot is explicitly a synthetic image, even with a real worker.
        w.timer.stop();qt.processEvents();w.centralWidget().layout().activate()
        w.health.setText('离线真实线程测试（合成图像） · '+w.health.text())
        assert w.grab().save(str(Path(os.environ['DEMO_TEST_ARTIFACTS'])/'threaded-pc-view.png'))
        w.close();assert not worker.is_alive()
        assert not worker.ready and not worker.connected
        peer.assert_closed()
        with peer.lock:
            assert peer.history[-1][2].kind==Kind.STREAM and peer.history[-1][2].payload==b'\x00'
            evidence('threaded-observations.json',dict(
                main_thread=main_id,worker_thread=peer.owner,timer_callbacks=len(timer_ids),
                timer_thread_ids=sorted(set(timer_ids)),commands=peer.commands,
                initial_session=token[1],write_commands=peer.writes(),
                final_actual=w.state['actual'],final_epoch=w.state['epoch'],final_image=w.image_metadata,
                unknown_observed_before_delayed_info=True,reconnect_blocked_until_info=True,
                old_packets_processed_before_qt_check=True,final_pixel_rgb=[19,19,19],
                accepted_image_frames=[17,18,19],old_image_frame_rejected=99,
                closed_socket_counts={str(port):s.closes for port,s in peer.sockets.items()},
                worker_alive=worker.is_alive(),hardware='NOT_RUN'))
        print('THREAD_QT_FLOW_PASS main_worker_distinct=1 timer_main_only=1 writes=2 unknown_observed=1 reconnect_info_only=1 images=3 sockets_closed=2')
    finally:
        peer.release();worker.stop_event.set();peer.wake.set();w.close();worker.join(timeout=1)
        w.deleteLater();QCoreApplication.sendPostedEvents(None,QEvent.Type.DeferredDelete);qt.processEvents()
        assert not worker.is_alive(),'real worker leaked after test'
    assert not worker.last_error


def test_real_thread_full_event_queue_stops_without_unbounded_backlog():
    peer=ThreadPeer();worker=peer.factory('host','board');main_id=threading.get_ident()
    worker.start()
    try:
        until(lambda:peer.info_count()>=1)
        assert worker.ident==peer.owner and peer.owner!=main_id
        for _ in range(40):
            if not worker.is_alive():break
            until(lambda:peer.completed_responses()>=peer.info_count() or not worker.is_alive())
            if not worker.is_alive():break
            old=peer.info_count();peer.advance(.51)
            until(lambda:peer.info_count()>old or not worker.is_alive())
        until(lambda:not worker.is_alive())
        assert worker.stop_event.is_set() and worker.events.qsize()==32
        assert worker.last_error=='UI event queue full; worker stopped'
        assert not worker.ready and not worker.connected and not peer.writes()
        peer.assert_closed()
        with peer.lock:
            evidence('threaded-overflow.json',dict(main_thread=main_id,worker_thread=peer.owner,
                queue_size=worker.events.qsize(),last_error=worker.last_error,info_commands=peer.info_count(),
                write_commands=len(peer.writes()),worker_alive=worker.is_alive(),
                closed_socket_counts={str(port):s.closes for port,s in peer.sockets.items()}))
        print('THREAD_QUEUE_BOUND_PASS queue_max=32 worker_exited=1 writes=0 sockets_closed=2')
    finally:
        peer.release();worker.stop_event.set();peer.wake.set();worker.join(timeout=1)
        assert not worker.is_alive(),'overflow worker leaked after test'
