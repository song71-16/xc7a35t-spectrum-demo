"""Demo same-raster PC view: python -m migration.touch_v1.demo.host.app.

Layout and Windows ICU binding derive from the existing ethernet.host.app.
Only an explicitly started app opens network sockets; tests inject a fake worker.
"""
from __future__ import annotations
import argparse
import math
import os
import queue
import time

if os.name == 'nt':
    import ctypes
    _system_icu = ctypes.WinDLL(os.path.join(os.environ['SystemRoot'], 'System32', 'icuuc.dll'))

from PySide6.QtCore import Qt, QTimer, QSignalBlocker, QCoreApplication, QEvent
from PySide6.QtGui import QImage, QPixmap, QFont, QFontDatabase
from PySide6.QtWidgets import (QApplication, QMainWindow, QWidget, QLabel, QPushButton,
                             QVBoxLayout, QHBoxLayout, QFormLayout, QSpinBox,
                             QDoubleSpinBox, QGroupBox)
from migration.touch_v1.ethernet.host.protocol import WIDTH, HEIGHT
from .transport import Receiver


class Window(QMainWindow):
    def __init__(self, bind, board, *, worker_factory=Receiver, clock=time.monotonic, image_observer=None):
        super().__init__()
        self.clock = clock
        self.image_observer = image_observer
        if os.name == 'nt' and 'Microsoft YaHei' not in QFontDatabase.families():
            font_path = os.path.join(os.environ['SystemRoot'], 'Fonts', 'msyh.ttc')
            if os.path.isfile(font_path):QFontDatabase.addApplicationFont(font_path)
        self.setFont(QFont('Microsoft YaHei', 10))
        self.setWindowTitle('频谱仪 · 双端调参展示')
        self.resize(1340, 780)
        self.worker = worker_factory(bind, board)
        self.token = (0, 0)
        self.ready = False
        self.state = {}
        self.dirty = set()
        self.need_initial_values = True
        self.image_metadata = None
        self.pixmap = None
        root = QWidget();layout = QVBoxLayout(root)
        title = QLabel('频谱仪  /  同源画面与双端调参')
        title.setStyleSheet('font-size: 24px; font-weight: 600;')
        layout.addWidget(title)
        layout.addWidget(QLabel(f'{bind} → {board}  ·  RGB888 1024 × 600'))
        body = QHBoxLayout()
        self.screen = QLabel('等待完整画面')
        self.screen.setAlignment(Qt.AlignmentFlag.AlignCenter)
        self.screen.setMinimumSize(640, 375)
        self.screen.setStyleSheet('background: #101820; color: #f1f5f9; border-radius: 6px;')
        body.addWidget(self.screen, 1)
        panel = QGroupBox('DDS 参数');form = QFormLayout(panel)
        self.actual = QLabel('尚未收到 FPGA 实际值');self.actual.setWordWrap(True)
        self.actual.setMinimumHeight(self.actual.fontMetrics().lineSpacing() * 5)
        form.addRow(QLabel('实际反馈'))
        form.addRow(self.actual)
        self.inputs = {16:QDoubleSpinBox(), 17:QSpinBox()}
        self.inputs[16].setRange(0, 2147483647);self.inputs[16].setDecimals(2)
        self.inputs[16].setSingleStep(1000)
        self.inputs[17].setRange(0, 32767)
        form.addRow('待提交频率 / Hz', self.inputs[16])
        form.addRow('待提交幅度 / Q15', self.inputs[17])
        for address, box in self.inputs.items():
            box.valueChanged.connect(lambda value, address=address:self.dirty.add(address))
        self.apply = QPushButton('提交修改');self.apply.clicked.connect(self.submit)
        self.stream = QPushButton('暂停图像传输');self.stream.setCheckable(True)
        self.stream.clicked.connect(self.toggle_stream)
        for button in (self.apply, self.stream):button.setMinimumHeight(36);form.addRow(button)
        self.message = QLabel('正在连接；首次读取前不能提交')
        self.message.setWordWrap(True);form.addRow(self.message)
        panel.setMinimumWidth(310);panel.setMaximumWidth(350)
        body.addWidget(panel);layout.addLayout(body, 1)
        self.health = QLabel('图像与当前控制反馈分别标识');layout.addWidget(self.health)
        self.setCentralWidget(root)
        self.apply.setEnabled(False);self.stream.setEnabled(False)
        self.worker.start()
        self.timer = QTimer(self);self.timer.timeout.connect(self.refresh);self.timer.start(16)

    def submit(self):
        if not self.ready or not self.dirty:
            return
        values = {}
        for address in self.dirty:
            value = self.inputs[address].value()
            if address == 16:
                fs = self.state['actual'][256]
                if not math.isfinite(value) or not 0 <= value < fs / 2:
                    self.message.setText('频率须在 0 到实际采样率一半之间。');return
                value = round(value * (1 << 32) / fs)
                if not 0 <= value <= 0x7fffffff:
                    self.message.setText('量化后的频率超出 DDS 范围。');return
            values[address] = value
        if self.worker.submit_edits(self.token, values):
            self.dirty.difference_update(values)
            self.message.setText('修改已进入 PC 队列，等待 FPGA 确认。')
        else:
            self.message.setText('当前未就绪，修改未提交；请等待实际值回读。')

    def toggle_stream(self, paused):
        if not self.worker.request_stream(self.token, not paused):
            self.message.setText('图像控制未被接纳，等待连接恢复。')

    def refresh(self):
        for _ in range(32):
            try:kind, token, value = self.worker.events.get_nowait()
            except queue.Empty:break
            if kind == 'session':
                if token[0] <= self.token[0]:continue
                self.token = token;self.ready = False;self.state = {}
                self.dirty.clear();self.need_initial_values = True
                self.actual.setText('新会话正在读取 FPGA；保留图像可能来自旧会话')
            elif token != self.token:
                continue
            elif kind == 'state':
                self.state = value;self.ready = value['ready']
                if self.ready and self.need_initial_values:
                    regs = value['actual'];fs = regs[256]
                    for address, box in self.inputs.items():
                        with QSignalBlocker(box):
                            box.setValue(regs[address] * fs / (1 << 32) if address == 16 else regs[address])
                    self.need_initial_values = False
                result = {'NONE':'尚无修改', 'PENDING':'待生效', 'APPLIED':'修改已确认',
                          'FAILED':'修改失败', 'UNKNOWN':'此前操作结果未知'}[value['result']]
                self.message.setText(result + ('；实际值已回读' if self.ready else '；等待实际状态确认'))
                with QSignalBlocker(self.stream):self.stream.setChecked(not value['stream'])
                self.stream.setText('暂停图像传输' if value['stream'] else '恢复图像传输')
            elif kind == 'edit_rejected':
                self.dirty.update(value['values'])
                self.message.setText('修改未被接纳；请在回读完成后重新提交。')
            elif kind in ('error', 'disconnected', 'stopped'):
                self.ready = False;self.message.setText(str(value))
            elif kind == 'notice':
                self.message.setText(str(value))
        if not self.worker.is_alive():
            self.ready = False
            self.message.setText(self.worker.last_error or '接收已停止')
        self.apply.setEnabled(self.ready and bool(self.dirty))
        self.stream.setEnabled(bool(self.state.get('connected')) and self.worker.is_alive())
        regs = self.state.get('actual', {})
        if regs:
            age = max(0, self.clock() - self.state['actual_at']) if self.state['actual_at'] is not None else 0
            qualification = '最近确认值' if self.ready else '旧反馈，仅供参考'
            self.actual.setText(f'{qualification} · {age:.1f} 秒前\n'
                                f'{regs[16] * regs[256] / (1 << 32):.2f} Hz  /  Q15 {regs[17]}\n'
                                f'配置版本 {self.state["epoch"]} · 反馈序号 {self.state["sequence"]}')
        with self.worker.lock:
            latest, self.worker.latest = self.worker.latest, None
            stats = dict(self.worker.stats)
        if latest is not None and latest[0] == self.token:
            token, image, received_at = latest
            qimage = QImage(image.rgb, WIDTH, HEIGHT, WIDTH*3, QImage.Format.Format_RGB888).copy()
            self.pixmap = QPixmap.fromImage(qimage)
            self.screen.setPixmap(self.pixmap.scaled(self.screen.size(), Qt.AspectRatioMode.KeepAspectRatio))
            self.image_metadata = (token, image.frame, image.source_frame, image.epoch, received_at)
            if self.image_observer is not None:
                self.image_observer(self.image_metadata, bytes(image.rgb))
        info = '尚无完整图像'
        if self.image_metadata:
            token, frame, source, epoch, received_at = self.image_metadata
            age = max(0, self.clock() - received_at)
            stale = token != self.token or not self.worker.connected or age > .5
            info = (f'{"保留旧图像" if stale else "收到的图像"} · 传输帧 {frame} · 采集帧 {source}'
                    f' · 图像配置版本 {epoch} · {age:.1f} 秒前；与控制反馈分别标识')
        self.health.setText(f'{info}  ·  完整帧 {stats.get("complete",0)}  ·  丢弃帧 {stats.get("dropped",0)}')

    def resizeEvent(self, event):
        super().resizeEvent(event)
        if getattr(self, 'pixmap', None):
            self.screen.setPixmap(self.pixmap.scaled(self.screen.size(), Qt.AspectRatioMode.KeepAspectRatio))

    def closeEvent(self, event):
        self.timer.stop();self.worker.stop_event.set();self.worker.join(timeout=1)
        event.accept()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--bind', default='192.168.10.1');parser.add_argument('--board', default='192.168.10.2')
    args = parser.parse_args();app = QApplication([]);app.setStyle('Fusion')
    window = Window(args.bind, args.board);window.show()
    try:return app.exec()
    finally:
        window.close();window.deleteLater()
        QCoreApplication.sendPostedEvents(None, QEvent.Type.DeferredDelete)


if __name__ == '__main__':raise SystemExit(main())
