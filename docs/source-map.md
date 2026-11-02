# 源基准与整理映射

原冻结交付 `up_event_demo_20261101`，原保存提交 `f6a248ea18cd723167465bcd67168bee78e77086`。原私有项目保持完整；新仓库独立初始化，不复制.git或fork历史。软件测试夹具来自已通过治理CI的 `a8cf213fb9b662fd137a069ad321c9d9e17e95a1`。

`source-map.json`逐项列原相对路径、目标路径、字节数、是否字节一致及适配。63个FPGA文件来自实际setup引用（保留原source层级），10个host运行文件来自host-source。旧生成器、TB输入和未引用模型不进入构建目录；bit/LTX暂不作为公开附件，完整原件仍保留在私有冻结交付中。

与日常源码对照时发现6个诊断差异，全部选择冻结版本，不混用：demo_eth_endpoint（ARP/header/tx/reject、D145）、demo_ft_frontend（控制域D147）、demo_ft_initialized_reader（init/run D13E/D146）、demo_ft_reader（80位诊断输出）、demo_touch_pc_top（诊断连线）、eth_phy（D144）。FT功能修复和PC5ms发送间隔与冻结运行源一致。

改动只限可移植性与整理：

1. VIO XCI的gen_directory与OUTPUTDIR从旧的上溯路径改为`.`，其余参数保持，避免新目录引用旧工程输出。
2. 新启动器使用项目venv/DEMO_PYTHON，配置PC地址，先做本地检查；冻结app/transport/协议实现未改。
3. 新prepare_project复制整个fpga输入树到不存在的新路径；不调用原生成器、不改RTL、不启动Vivado。setup原文保留。
4. 测试移动到tests，调整一个helper import，沿用已验证假时钟fixture；不修改运行程序。
5. 报告保留厂商声明和检查内容，仅删除工作站Host及本地绝对路径行；图片像素和原结果JSON未修改。原版报告留在私有冻结包。
6. 不搬入网卡MAC、板序列号、机器名、旧个人网段、长交接、缓存、手册或完整运行目录。结果中的token/session是已经结束的UDP演示会话标识，不是GitHub/API凭据。

原85项中未选入项也在JSON明确列出理由，不擅自重写原清单或创建独立摘要。新清单只记录映射与大小；固定Git标签标识公开版本。旧源码中PREPARED/NOT_RUN注释是形成时间记录，当前验证范围以verification.md为准。
