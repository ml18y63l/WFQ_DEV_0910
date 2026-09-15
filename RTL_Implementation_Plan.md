# wfq_tag_sort_engine RTL 分阶段实施记录

设计基线：`Design_Spec_V1.2.md`。编码风格：`RTL_Coding_Style.md` v1.7。
实现语言：Verilog-2001，源文件为 `.v` / `.vh`；基础 testbench 同样使用 Verilog-2001。
记录日期：2026-09-15。

当前完成阶段 1：基础模块、单元仿真和初始化存储集成测试。完整排序引擎的顶层、事务控制及吞吐验证在后续阶段完成。

## 1. 阶段划分与验收边界

| 阶段 | 主要交付 | 阶段验收 | 状态 |
| :--- | :--- | :--- | :--- |
| 1：基础模块 | Matcher、复位同步器、L1/L2 寄存器、1RW/1R1W RAM、初始化控制、公共常量函数 | Matcher 穷举；0/1 拍读契约；旁路；初始化与参数检查 | 已完成，见 `verification/RTL_Stage1_Report.md` |
| 2：Trie 与键元数据 | `wfq_trie_search`、TT/RC 管理及精确 marker 更新 | A/B/C 路径、唯一备用叶、重复键、最后引用清除、两个 bank 隔离；分别检查 I=5/6 的读排程 | 待实现 |
| 3：准入与资源控制 | FREE 栈、epoch 窗口、RR 仲裁、容量预留、两项响应 FIFO | 满空边界；第三 epoch 背压；回绕；保守响应信用；不变量与仲裁公平性 | 待实现 |
| 4：链表事务与顶层 | List manager、head cache、commit 描述符、pending overlay、两个上下文、故障控制、`wfq_tag_sort_engine` | 原子提交；稳定 FCFS；跨代全局排序；NEXT 延迟修补；写回完成；顶层端口与固定周期 | 待实现 |
| 5：完整验收与实现评估 | 顶层参考模型对拍、F01–F34、随机/故障注入、目标存储映射、综合与 STA | 两种 ISSUE_INTERVAL 的完整周期验证；无副本存储映射；根据实际 f5/5 与 f6/6 比较性能 | 待实现 |

每阶段交付实际 RTL、对应测试和结果记录。阶段内可使用 testbench 提供尚未实现的上游/下游激励，但必须说明验证边界。阶段 1 没有加入只有端口而无功能的顶层占位模块。

## 2. 阶段 1 文件与功能

| 文件 | 功能与当前接口 |
| :--- | :--- |
| `rtl/wfq_matcher16.v` | 4×4 分组组合匹配器，输入 bitmap/query/mode，输出 found/index/onehot/exact |
| `rtl/wfq_trie_upper_regs.v` | 两个 L1 word、32 个 L2 word，共 544 bit 权威寄存器状态；每级一个整字写接口；选址读取和 flat 读取均为组合逻辑 |
| `rtl/wfq_sync_ram_1rw.v` | L3 所用同步单端口 RAM；共用一个地址，读写互斥；冲突输出 `access_conflict` 并抑制本 RAM 的两种访问 |
| `rtl/wfq_sync_ram_1r1w.v` | 通用同步一读一写 RAM；捕获新提交、pending 和同沿物理写的读旁路 |
| `rtl/wfq_reset_sync.v` | 异步置低、两级同步释放的公共复位同步器 |
| `rtl/wfq_init_ctrl.v` | TT/RC、L1/L2/L3、FREE 的并行初始化控制及 guard；默认 PTR_WIDTH=10、MEM_DEPTH=1024 |
| `rtl/include/wfq_defs.vh` | Matcher 模式及 fault code 编码；无可变状态 |
| `rtl/include/wfq_clog2.vh` | 模块内常量函数，计算派生位宽；每个使用模块包含一次，不设置跨模块 include guard |
| `rtl/files.f` | 当前已实现 RTL 的编译清单 |

参数化 RAM 和初始化模块沿用规格 §4.1 的非 ANSI 声明方式：在模块内部定义 `wfq_clog2` 和 `ADDR_WIDTH` 后声明完整的 `input wire` / `output wire` 端口。ADDR_WIDTH 不允许外部覆盖。其余模块使用 ANSI 端口声明。接口信号名、wire/reg 声明及连接括号按风格文件保持文件内统一竖线；当前 RTL 声明统一使用第 57 列。

所有控制寄存器采用异步低有效复位，时序变量使用 `_d` 或纯延迟链的 `_d1` / `_d2`。RAM 阵列及模拟宏内部读数据的寄存器按风格 §7.4 不加复位；写使能和 read_valid 在复位时被抑制。

## 3. 后续集成必须保持的接口契约

### 3.1 L1/L2 状态与写入口

`l1_flat[16*bank +: 16]` 对应 L1[bank]；`l2_flat[16*{bank,a} +: 16]` 对应 L2[bank,a]。flat 输出只是同一组寄存器的连线，可供 FAST5 并行 MAX 网络使用。

每级写接口接收已经计算好的完整 16-bit 新值。后续 Trie/commit 控制器负责根据旧精确快照合并 set/clear，并保证 RC、TT、Trie 的更新原子性。初始化与正常提交在外部仲裁，不能同时驱动同级写端口。组合读口不提供“时钟沿前看到未来写入”的旁路；写入沿更新后自然读出新值。

### 3.2 RAM 延迟与旁路

在 E_k 采样 `read_en` 和地址，读数据与 read_valid 在 E_k 后的周期有效，消费级在 E_(k+1) 使用。宏内部读数据寄存器就是这一拍读延迟，不再增加输出数据寄存器。物理写在其使能采样沿生效，替换 SRAM/BRAM 宏时必须保持此契约。

1R1W 的选择顺序是：

```text
本沿新逻辑提交且同址
    > 最新 pending 逻辑写且同址
    > 本沿物理写且同址
    > 原始 RAM 读数据
```

物理写的同址转发是对宏 read-during-write 行为的封装，不代表物理写拥有更高的事务顺序。NEXT 的延迟修补应进入 pending 语义；新逻辑提交必须优先。`valid` 独立于 data，因此 0、NULL 和 TT invalid 都能转发。

调用方若持有多个 pending 写项，必须先按**读地址匹配，再选择其中最新的一项**，送入当前单项 pending 接口。这里不保存完整事务上下文，也不负责指针合法性或 pending 项的生命周期。读事务的 label/context_id 由调用方随 `read_en` 同沿打拍，与返回的 read_valid 对齐。

RAM 仅接受已经检查过的物理地址。后续 FREE/list/commit 控制必须在缩窄地址前完成较宽指针、栈索引和 link.valid 检查。默认 10/1024 的所有 1024 个节点地址均可使用；不存在 sentinel 地址。

L3 的冲突指示为组合诊断信号。最终 commit 控制器必须在同一沿前检查端口请求，并在出现故障时抑制**整笔事务的全部写入**、锁存 fault code=6。单独抑制 L3 写入不能替代全局原子故障控制。

### 3.3 复位与初始化所有权

顶层只实例化一个公共复位同步器，将 `core_rstn` 接到所有叶子模块的 `rstn`；各叶子不重复串接同步器。综合/物理实现阶段需要保留并约束这两个同步级。

`wfq_init_ctrl` 的写输出是将要在下一个上升沿采样的控制。`init_guard=1` 表示本周期即将到达 guard 沿，供状态所有者同步装载 free_count=MEM_DEPTH、queue_level=0、alloc_reserved=0，并清除 bank/cache/context/FIFO/RR/cooldown 状态；这些状态本身在后续阶段实现。

默认扫描最后写沿为 R8191，guard 沿 R8192 更新 init_done；最早可接受请求沿为 R8193。MEM_DEPTH=65536 时分别为 R65535、R65536、R65537。扫描计数器独立派生，默认 14 bit、最大容量 17 bit。

初始化清 TT/RC 和 Trie，并写 FREE[i]=i；DATA/NEXT 不清零。运行中复位会重新开始扫描。最终顶层的 ready、busy、idle、full 和响应屏蔽仍由后续控制模块完成。

### 3.4 后续事务字段与周期

后续 LINK 编码固定为 `{valid, ptr}`，payload 固定为 `{epoch, tag, flow_id}`，分别为默认 11 bit 和 37 bit。完整 commit 描述符将在阶段 4 定义字段、位段和唯一所有者，采用 Verilog 定宽向量及局部派生常量，不使用 SystemVerilog struct/package。

阶段 2 和阶段 4 统一由 ISSUE_INTERVAL=5/6 派生备用叶读、TT 读、NEXT 读、提交、修补和写回完成周期。不能因为模块边界增加额外读延迟或描述符寄存器级。固定周期和完整吞吐指标需待顶层事务排程实现后验证。

## 4. 运行与复现

在项目根目录运行完整阶段 1 回归：

```powershell
py -3 -B scripts/run_stage1.py
```

只做日常快速检查可追加 `--quick`，它跳过 Matcher 穷举，其余用例仍运行。独立风格检查为 `py -3 -B scripts/check_rtl_style.py`。

回归脚本用 `iverilog -g2001 -Wall` 编译，合法配置不允许 warning；使用 Verilog testbench 的显式 PASS/FAIL 判断结果。输出位于 `build/stage1/`，包含工具版本、逐用例编译/运行日志、`results.json` 和源文件 SHA256。运行开始标记 RUNNING，失败标记 FAIL，避免误用旧的 PASS 结果。

脚本优先使用 `IVERILOG` / `VVP` 指定的可执行文件，其次查找 PATH，最后使用项目内 `.tools/iverilog/mingw64/bin/`。当前已准备 Icarus Verilog 13.0；所有包来源和 SHA256 固定在 `scripts/iverilog_msys2.lock.json`。Windows 新环境可显式运行 `py -3 -B scripts/setup_iverilog.py` 恢复工具缓存，需 Python、zstandard、curl 和网络访问。该脚本校验 SHA256，仅解压到项目目录；日常回归不会联网或修改系统 PATH。

完整引擎的 F01–F34、故障控制、综合映射、资源利用率及 STA 尚未完成。阶段 1 的仿真通过只证明当前模块和初始化连接的已测行为，不作为 f_clk/5 或 f_clk/6 的性能结果。
