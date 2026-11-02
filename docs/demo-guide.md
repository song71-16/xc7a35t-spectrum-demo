# 接线、地址与展示

适用已验证的达芬奇 non-Pro 板、对应7寸1024×600 RGB/触控屏及YT8531C以太网。板型/屏幕修订或连接器方向不一致时先停止核对，不能只凭XC7A35T型号套用位流。

## 接线

断电后连接匹配的RGB屏排线到板载LCD接口，检查排线方向、针1和板/屏标注；触控SCL/SDA/INT/RST同该接口定义。板载RJ45连接PC有线网口，USB JTAG连接电脑；按原板/屏说明使用匹配电源。不要将屏幕背光/电源误接到FPGA信号脚，不依据LVCMOS33信号标准推断屏幕供电。

XDC是提交版本的准确封装引脚依据：

| 信号 | FPGA封装引脚 |
|---|---|
| sys_clk / sys_rst_n | R4 / U2 |
| lcd_clk / HS / VS / DE | Y9 / V8 / U7 / AB7 |
| lcd_bl / lcd_rst | V7 / W7 |
| touch_scl / sda / int / rst | Y8 / AB8 / Y7 / AB6 |
| eth_rst_n / MDC / MDIO | T21 / U22 / U21 |

RGB24和RGMII的完整逐位引脚见 `fpga/source/migration/touch_v1/demo/configs/demo_lcd_touch.xdc` 与 `fpga/source/migration/touch_v1/ethernet/configs/ethernet_nonpro.xdc`。表中的封装球位不是排线连接器针号。官方板/屏原理图由制造商提供，本仓库不复制厂商手册；取得对应版本后核对方向与电气。

## 地址和端口

冻结固件板地址192.168.10.2，PC地址192.168.10.1，掩码255.255.255.0（示例/板端约定，不是私有个人网络信息）。UDP50000为图像、50001为控制。PC自行配置匹配有线接口，保留其他工作网络时注意源地址选择；确认防火墙按需允许本程序，而不是关闭整个防火墙。启动器不更改这些设置，不发探测包。

`--offline-check`只查依赖与地址语法；`--preflight`进一步读取本地网卡并短暂绑定本地两端口，仍不向板发送数据；正式启动才通信。只开一个PC窗口。

## 演示和故障处理

已有镜像运行后，LCD应显示双时域/FIR频谱及PRESET1/2/3、AMP−/AMP+。PC等待连通、回读实际值和新图像。若初始化等待首次有效触控，轻触中心再松开，待TOUCH READY；按下时RELEASE TO ARM为状态提示。持续UNAVAILABLE/故障应留证停止。

每次只做一个动作：触控一个不同PRESET并松开，观察实际频率/phase和epoch变化；再PC改一个幅度值，等待APPLIED、INFO回读和对应epoch新图像。即使PC输入框显示新值，也要等实际值和图像确认。图片缓存过期/断连时不把旧画面当最新。

端口占用：退出其他接收窗口后重新做本地检查；依赖缺失：在项目venv安装requirements；未连接：核有线地址/链路/原固件配置，不自动改网卡或防火墙。控制UNKNOWN/FAILED时保留结果，不自动重发WRITE；数据源可能超时，不能连续点击掩盖错误。硬件错误停止，不盲目复位/下载/扫地址。

SRAM断电丢失镜像，恢复需另行按器件身份、产物、时序门禁下载；没有Flash自动恢复。本轮没有确认任何当前板上状态，也没有执行下载。
