# 第三方来源与声明

## 正点原子触控I²C驱动

文件：`fpga/source/migration/touch_v1/demo/rtl/demo_touch_i2c.v`，源自官方 `29_top_lcd_touch/rtl/touch/i2c_dri.v`。原头部与署名字节完整保留（原包部分非ASCII注释编码显示异常，本轮未重写）。原声明为正点原子2023–2033、All rights reserved；项目修改包括事务字段锁存、最后读NACK、写NACK停止及SDA开漏，原时钟分频/SCL序列保留。

官方入口：[正点原子资料下载中心](https://www.openedv.com/docs/build/html/index.html)、[正点原子官方GitHub组织](https://github.com/alientek-openedv)。公开可下载和“开源免费”概述不单独证明此具体修改版的再分发条款。本轮未取得明确条款；所有者要求保留声明后公开，不把该文件改授MIT。参阅LICENSE_SCOPE.md中的未核实限制。

## AMD/Xilinx

XCI仅用于保存配置：[Vivado2023.2 IP sources说明](https://docs.amd.com/r/2023.2-English/ug895-vivado-system-level-design-entry/Working-with-IP-Sources)。FFT、VIO、XPM和器件原语由用户合法安装的Vivado2023.2生成/提供，适用AMD对应工具/IP许可，不属于本项目MIT源码。见[AMD许可FAQ](https://www.amd.com/en/products/software/adaptive-socs-and-fpgas/licensing-faq.html)。报告中的AMD/Xilinx版权声明保留。未附IP生成网表、工具或license文件。

## PC依赖

- PySide6 / Qt for Python：按[官方许可证说明](https://doc.qt.io/qtforpython-6/licenses.html)选择适用LGPLv3/GPLv3或商业许可；不同Qt模块须按其条款。通过用户venv安装，未将Qt二进制打包入仓库。
- psutil：BSD-3-Clause；pytest：MIT；pyserial：BSD-3-Clause（仅离线测试防护导入）。依赖由requirements安装，保留包自带许可，未复制它们的实现到项目。
- Python：由用户安装，适用Python发行版条款。

原项目Windows串口soak_transport的pySerial衍生实现不属于此展示依赖，未复制到本仓库。也未复制厂商PDF、官方完整例程工程或无关存储研究组件。
