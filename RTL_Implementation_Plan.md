# wfq_tag_sort_engine RTL 分阶段实施记录

设计基线：`Design_Spec_V1.2.md`。编码风格：`RTL_Coding_Style.md` v1.7。
实现语言：Verilog-2001，源文件为 `.v` / `.vh`；基础 testbench 同样使用 Verilog-2001。
记录日期：2026-09-16（阶段 1 完成于 2026-09-15）。

当前完成阶段 1～4 的 FAST5 实现，完整 `wfq_tag_sort_engine` 已集成并通过第四阶段顶层回归。按最新实施要求，当前只实现 ISSUE_INTERVAL=5：插入 E4 提交、E5 修补前驱 NEXT、E6 写回完成；出队 E1 提交、E2 写回完成。真实链表、元数据和资源控制已联合验证连续五拍发射及统一故障门控。最终长随机验收、目标存储映射和综合/STA 属于阶段 5。

## 1. 阶段划分与验收边界

| 阶段 | 主要交付 | 阶段验收 | 状态 |
| :--- | :--- | :--- | :--- |
| 1：基础模块 | Matcher、复位同步器、L1/L2 寄存器、1RW/1R1W RAM、初始化控制、公共常量函数 | Matcher 穷举；0/1 拍读契约；旁路；初始化与参数检查 | 已完成，见 `verification/RTL_Stage1_Report.md` |
| 2：Trie 与键元数据 | `wfq_trie_search`、TT/RC 管理及精确 marker 更新 | A/B/C 路径、唯一备用叶、重复键、最后引用清除、两个 bank 隔离；FAST5 逐沿排程和每五拍发射 | FAST5 已完成，见 `verification/RTL_Stage2_Report.md`；PIPE6 暂缓 |
| 3：准入与资源控制 | FREE 栈、epoch 窗口、RR 仲裁、容量预留、两项响应 FIFO | 满空边界；第三 epoch 背压；回绕；保守响应信用；不变量与仲裁公平性 | FAST5 已完成，见 `verification/RTL_Stage3_Report.md` |
| 4：链表事务与顶层 | List manager、head cache、commit 描述符、pending overlay、两个上下文、故障控制、`wfq_tag_sort_engine` | 原子提交；稳定 FCFS；跨代全局排序；NEXT 延迟修补；写回完成；顶层端口与固定周期 | FAST5 已完成，见 `verification/RTL_Stage4_Report.md` |
| 5：功能验收 | 顶层逐项对拍、定向/参数/故障回归、长随机、覆盖记录 | FAST5 每种默认容量配置 10 个种子×100,000 次随机接受；F01–F34 按实施范围追踪 | 执行中；综合/STA 按用户要求暂缓，PIPE6 未实现 |

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

`wfq_init_ctrl` 的写输出是将要在下一个上升沿采样的控制。`init_guard=1` 表示本周期即将到达 guard 沿，供状态所有者同步装载 free_count=MEM_DEPTH、queue_level=0、alloc_reserved=0，并清除 bank/cache/context/FIFO/RR/cooldown 状态；这些状态由资源、链表和上下文控制模块分别拥有。

默认扫描最后写沿为 R8191，guard 沿 R8192 更新 init_done；最早可接受请求沿为 R8193。MEM_DEPTH=65536 时分别为 R65535、R65536、R65537。扫描计数器独立派生，默认 14 bit、最大容量 17 bit。

初始化清 TT/RC 和 Trie，并写 FREE[i]=i；DATA/NEXT 不清零。运行中复位会重新开始扫描。顶层的 ready、busy、idle、full 和响应屏蔽已在阶段 4 接通；busy 覆盖到写回完成，idle 还要求无未消费响应、无响应预留且无 fault。

### 3.4 事务字段与周期

LINK 编码固定为 `{valid, ptr}`，payload 固定为 `{epoch, tag, flow_id}`，分别为默认 11 bit 和 37 bit。阶段 4 的链表提交描述符采用定宽向量 `{payload, n, p, successor}`，由 `wfq_list_manager` 独占；字段和上下文生命周期见 §8。全部使用 Verilog 局部派生常量，不使用 SystemVerilog struct/package。

当前事务控制只接受 ISSUE_INTERVAL=5，备用叶读、TT 读、前驱交付和提交周期仍由 ISSUE_INTERVAL 派生。规格允许的 PIPE6 尚未编码，当前传入 6 会明确拒绝展开，不能把同一套 FAST5 连线直接改常数后当作 PIPE6。模块边界没有增加同步读延迟或提交等待拍；第四阶段已经验证全引擎固定周期和五拍发射，实际 f_clk 仍需综合与 STA。

## 4. 运行与复现

在项目根目录运行完整阶段 1 回归：

```powershell
py -3 -B scripts/run_stage1.py
```

只做日常快速检查可追加 `--quick`，它跳过 Matcher 穷举，其余用例仍运行。独立风格检查为 `py -3 -B scripts/check_rtl_style.py`。

回归脚本用 `iverilog -g2001 -Wall` 编译，合法配置不允许 warning；使用 Verilog testbench 的显式 PASS/FAIL 判断结果。输出位于 `build/stage1/`，包含工具版本、逐用例编译/运行日志、`results.json` 和源文件 SHA256。运行开始标记 RUNNING，失败标记 FAIL，避免误用旧的 PASS 结果。

脚本优先使用 `IVERILOG` / `VVP` 指定的可执行文件，其次查找 PATH，最后使用项目内 `.tools/iverilog/mingw64/bin/`。当前已准备 Icarus Verilog 13.0；所有包来源和 SHA256 固定在 `scripts/iverilog_msys2.lock.json`。Windows 新环境可显式运行 `py -3 -B scripts/setup_iverilog.py` 恢复工具缓存，需 Python、zstandard、curl 和网络访问。该脚本校验 SHA256，仅解压到项目目录；日常回归不会联网或修改系统 PATH。

基础模块、元数据、资源控制和完整顶层的阶段结果分别记录在阶段 1～4 报告中。第四阶段已经覆盖链表/元数据/资源的全域故障集成；F01–F34 的最终验收矩阵、规定规模的长随机、综合映射、资源利用率及 STA 尚未完成。

## 5. 阶段 2：FAST5 Trie 与键元数据

新增模块全部使用 Verilog-2001，纳入 `rtl/files.f`：

| 文件 | 职责 |
| :--- | :--- |
| `rtl/wfq_trie_search.v` | 同 bank 的 A/B/C/无前驱搜索；32 个 L2 MAX 并行前视；保留精确根/父/叶快照 |
| `rtl/wfq_translation_table.v` | 一份 8192 项 TT，数据为 `{valid,ptr}`；同键尾指针 |
| `rtl/wfq_tag_refcount_array.v` | 一份 8192 项 RC，字宽由 MEM_DEPTH 派生 |
| `rtl/wfq_metadata_update.v` | 组合生成 RC/TT/Trie 更新计划，检查计数、精确 marker 和指针范围；只写必要的父/根 |
| `rtl/wfq_key_metadata.v` | 集成搜索、存储、快照、E3 提交主体、统一元数据写门控、局部故障和五拍发射窗口 |

L1/L2 继续使用阶段 1 的唯一寄存器实例，L3 继续使用唯一 512×16 单端口实例。TT/RC 不存在延迟物理修补，直接在提交沿写入，因此当前表封装不需要 pending 项；同沿物理写的读旁路仍由公共 RAM 封装提供。

### 5.1 实际边沿

| 边沿 | 插入 | 出队 |
| :--- | :--- | :--- |
| E0 | 请求握手；读 RC 和精确 L3 | 请求握手；读旧头键的 RC 和精确 L3 |
| E1 | 验证并捕获 alloc_ptr、RC、精确快照；A 未命中时最多一次备用 L3 读 | 从 RAM q 直接计算清除/递减并提交 |
| E2 | 最终同 bank 前驱 tag 直接驱动 TT 读 | 无元数据访问 |
| E3 | TT q 给出前驱指针；对外提供 pred_valid；内部锁存元数据提交主体 | 无元数据访问 |
| E4 | 在统一 commit_fire 门控下提交 RC/TT/必要 Trie | 无元数据访问 |
| E5 | 可接受下一请求 | 可接受下一请求 |

表中信号在所列采样沿**之前**有效。例如 pred_valid 在 E2 后至 E3 之前的周期有效，调用方可直接在 E3 读 NEXT，不得等到 E3 再打一拍后于 E4 才读。插入 prepare_valid 同样在 E3 之前有效；出队 prepare_valid 在 E1 之前有效。

### 5.2 后续集成接口

| 接口 | 调用约定 |
| :--- | :--- |
| request_valid/request_ready | 单通道元数据握手。request_insert 选择插入/出队，携带 bank、tag 和 1-bit context。ready 只检查初始化、局部故障和发射窗口，不检查全局容量、epoch、响应信用或 RR |
| alloc_valid/alloc_context/alloc_ptr | 插入 E1 的 FREE 返回值，context 必须等于 E0 请求；缺失/归属错误报 code=6，较宽指针越界报 code=7。出队忽略此接口 |
| pred_valid/found/tag/ptr/exact/path | 插入 E3 前的同 bank 前驱，path=0/1/2/3 分别为无/A/B/C。found=0 时由外部 epoch/list 控制选择旧代尾或 NULL，不能解引用默认 ptr=0 |
| prepare_valid/old_count/new_count | 插入 E3、出队 E1 前的元数据结果；完整元数据写主体由子系统自己保留 |
| commit_due / commit_ok | 固定提交沿到达 / 本域检查通过；commit_ok 不代表链表、容量或 epoch 已通过 |
| commit_allow | 外部全局提交控制在同沿前给出许可，与 commit_ok 合成 commit_fire。低电平表示取消本次提交，不能增加内部等待或重试 |
| commit_fire / commit_done | 前者是沿前组合门控，必须用于同沿写入和状态更新；后者是沿后保持一拍的提交指示 |
| error_valid/error_code | 本沿前的局部事件；全局控制必须与其他事件按最小非零编码汇总，并在本沿抑制所有相关写入 |
| fault/fault_code / halt | 本域首次故障的 sticky 状态 / 外部全局停止服务状态；恢复依赖复位和完整初始化 |
| init_done/init_write_en/init_write_addr | 来自共享初始化控制器，后两项接其 meta_write_en/meta_write_addr；按地址范围并行清 L1/L2/L3/TT/RC |

外部检查失败时必须在提交沿前撤销 commit_allow，并按全局 fail-stop 协议置 fault/halt，不能让 DATA/NEXT、bank/count 或响应 FIFO 部分更新。测试中的只读搜索探测使用 commit_allow=0 验证写门控，不代表正常顶层允许静默丢弃已接受请求。

较宽指针在 E1 分配返回和 E3 TT 返回处先检查范围。无效 RAM 返回只形成阶段错误，不使用其任意 data 推断 RC 或 marker 错误。有效结果的多错误同沿仍取最小非零编码。

### 5.3 状态所有权

本模块只有一个尚未提交的元数据事务，与五拍发射、插入 E4 提交相容。完整引擎的两个执行/写回上下文由外部 list/commit 控制拥有：旧插入 E5 的 NEXT 修补和 E6 的写回完成不能依赖本模块继续保存工作字段。新请求可在 E5 覆盖这些字段，外部必须早已保存旧事务所需的 n/p/successor/context。

阶段 2 单独验证元数据域的固定边沿、无内部重试和连续每五拍接受能力。阶段 3 完成资源域；阶段 4 已接入 DATA/NEXT、head cache、写回上下文和全域提交门控，并获得完整引擎五拍发射的周期仿真结果。尚无 MHz 测量结果。

## 6. 阶段 2 验证入口

```powershell
py -3 -B scripts/run_stage2.py
```

完整回归包含更新逻辑穷举/随机检查、双 bank 全 tag 探测、满容量同键填充/排空、连续五拍混合流量和故障注入。`--quick` 跳过全 tag 扫描并缩短混合流量。结果、逐用例日志和源文件 SHA256 写入 `build/stage2/`；合法配置必须在 `-g2001 -Wall` 下无 warning。

阶段 2 的详细覆盖见 `verification/RTL_Stage2_Report.md`。阶段 3 结果和后续接入约定如下。

## 7. 阶段 3：FAST5 准入与资源控制

| 文件 | 状态所有权与行为 |
| :--- | :--- |
| `rtl/wfq_admission_ctrl.v` | 独占 RR 优先权和五拍冷却计数；复位首次冲突优先出队；无合格请求时保持可发射 |
| `rtl/wfq_free_slot_stack.v` | 一份 MEM_DEPTH×PTR_WIDTH 同步 1R1W FREE RAM；独占 free_count、alloc_reserved、queue_level |
| `rtl/wfq_epoch_ctrl.v` | 独占 base_epoch、bank_valid、两个完整 bank_epoch 和 bank_count；16-bit 模加和空队列重建 |
| `rtl/wfq_response_fifo.v` | 两项完整 payload 寄存器、读写位置、rsp_count/rsp_reserved；保守信用、沿后 valid、故障后消费 |
| `rtl/wfq_resource_ctrl.v` | 集成上述模块；一个未提交资源事务；检查提交时刻/归属；汇总内外部沿前事件并锁存首次 fault |

五个模块均采用 Verilog-2001，列入 `rtl/files.f`。容量计数由 MEM_DEPTH 派生，默认仍为 11 bit；指针默认 10 bit。FREE 数组按 MEM_DEPTH 定义，初始化仍由公共 `wfq_init_ctrl` 扫描，不通过 reset 清整块 RAM。

### 7.1 固定时序与准入

| 沿 | 插入 | 出队 |
| :--- | :--- | :--- |
| E0 | 仲裁接受，直接读 FREE[旧 free_count−1]；free_count−−、alloc_reserved++ | 仲裁接受，rsp_reserved++ |
| E1 | FREE q 和 context 可被消费；检查返回有效性及较宽指针范围 | 同一门控下释放旧头地址、更新容量/bank、产生完整响应 |
| E4 | alloc_reserved−−、queue_level++、建立/更新所属 bank | 无本域提交 |
| E5 | 最早可接受下一操作 | 最早可接受下一操作 |

响应 FIFO 原空时，E1 沿后 valid/data 有效，最早 E2 消费。沿前 `rsp_count+rsp_reserved<2` 才能接受出队，不预支该沿的消费；满队列也不预支待释放地址。FREE 指针在 E1 返回，未增加输出寄存级。

冷却只约束两次接受的最小间隔。E5 无合格请求而 E6 出现合格请求时可直接在 E6 接受，不需等待下一组五拍边界。RR 只随实际接受改变；容量/epoch/响应信用不合格的一方不能阻挡另一方。

### 7.2 阶段 4 接入契约

| 接口 | 约定 |
| :--- | :--- |
| `insert_val/insert_epoch/extract_req` | 来自顶层请求；本域只捕获资源检查所需的 epoch/类型/context，tag/Flow ID 由外部事务上下文捕获 |
| `request_context/context_available` | 外部两个执行/写回上下文的选择及可用性；有合格候选但无可用上下文时沿前 code=6，不以背压隐藏调度错误 |
| `path_ready` | 存储/执行路径可接收，例如阶段 2 的 request_ready；正常五拍排程下应可用，不可用且存在合格候选报 code=6 |
| `insert_ready/extract_ready、*_fire` | 已经资源资格、RR 和公共错误门控的实际握手；每沿最多一个。将 fire 的并集送给元数据 request_valid |
| `alloc_valid/alloc_context/alloc_ptr` | 插入 E1 前的原始返回及归属。valid 表示 RAM 返回有效，**不表示指针范围正确**；不得用组合 cycle_allow 反向屏蔽它，否则可能形成错误反馈或把 code=7 变成 code=6 |
| `commit_req/insert/context/epoch` | 外部 list/commit 控制器给出的**未经过错误门控的提交请求**。插入必须在 E4、出队在 E1；本域核对 deadline、类型、context 和已接受 epoch |
| `release_ptr/response_payload` | 出队 E1 前的旧头指针与完整 `{epoch,tag,flow_id}`；本域检查指针范围和 payload epoch，实际头链路/内容一致性由 list 检查 |
| `external_error_code` | 来自 metadata、list、cache、pending/端口/上下文等外部检查器的最小非零沿前事件；不能先经过提交许可屏蔽 |
| `error_valid/error_code` | 本域与 external_error_code 取最小非零后的组合事件；发生当沿即 inhibit，随后锁存首次 fault/code |
| `cycle_allow` | 本沿统一许可，应连接元数据 commit_allow，并共同控制 list/cache/DATA/NEXT 的正常修改和物理写；不是仅供本域使用的许可 |
| `commit_fire` | `commit_req && cycle_allow`，是沿前实际提交；沿后提交脉冲由后续顶层打拍生成 |
| `halt/fault` | 停止新接受及在途修改；已提交响应继续消费。halt 用于停服/取消，不能作为保持固定时延的暂停恢复协议；恢复走复位和完整初始化 |

正常路径不能把 `commit_fire` 接回 `commit_req`：事件检查必须独立于最终许可。外部错误发生时仍保留原提交请求参与检查，再由 cycle_allow 抑制所有写入。否则既可能形成组合环，也可能掩盖原始错误。

本域未提交事务在 E4/E1 结束，**不等同于执行/写回上下文释放**。旧插入的 E5 NEXT 修补和 E6 写回完成仍由阶段 4 的独立上下文保存；busy/idle 也由完整上下文及响应状态计算，不能使用本域 active 代替 busy。

bank 的 head/tail/min/max 仍属于 list manager；本阶段只管理身份、valid 和 count。bank 清空复用依赖元数据域在同一提交沿精确归零，阶段 4 必须通过 cycle_allow 联动所有状态，不能仅连接计数。

### 7.3 验证入口与下一阶段

```powershell
py -3 -B scripts/run_stage3.py
```

完整回归包含 14 项仿真、6 项配置拒绝检查；使用 `-g2001 -Wall`，合法展开不允许 warning。四组资源集成配置各运行 30,000 个随机激励周期，另含全容量、两代回绕、全 65,536 个 epoch 查询值、RR 和定向背压。`--quick` 将随机段缩至每配置 2,000 周期，其余组件测试和故障注入保持不变。

结果、日志和源文件 SHA256 位于 `build/stage3/`；详细范围和数值见 `verification/RTL_Stage3_Report.md`。第三阶段测试仍保留资源子系统的独立测试方式，由 testbench 提供链表头/payload/提交请求；真实链表与资源、元数据的集成由第四阶段顶层测试覆盖。

## 8. 阶段 4：FAST5 链表与完整顶层

新增三个功能模块，均列入 `rtl/files.f`，全项目目前为 19 个 RTL 模块及两个 include：

| 文件 | 状态所有权与行为 |
| :--- | :--- |
| `rtl/wfq_commit_ctrl.v` | 两个执行/写回上下文，保存 valid/type/age/committed；产生未经过许可门控的提交、NEXT 修补和写回完成 deadline |
| `rtl/wfq_list_manager.v` | 单份 DATA/NEXT RAM、全局 head/tail、head cache、各 bank 的 head/tail/min/max、一个未提交工作快照、E3 主体和两个最终 pending 描述符 |
| `rtl/wfq_tag_sort_engine.v` | V1.2 顶层接口；公共复位/初始化；元数据、资源、链表、上下文控制连接；公共 fault 门控及沿后提交脉冲 |

资源模块继续独占容量、bank 身份/计数和响应状态；元数据模块继续独占 Trie/TT/RC。各模块只有一份权威状态。L1/L2 仍为单份组合读寄存器，L3 仍为单份同步 1RW，DATA/NEXT/TT/RC/FREE 均为单份同步 1R1W。

### 8.1 描述符与固定排程

令 `P=PTR_WIDTH`、`L=P+1`、`D=28+FLOW_ID_WIDTH`。链表描述符宽度为 `D+P+2*L`，默认 69 bit，低位到高位依次为 successor/旧头快照、前驱 link p、新节点指针 n、payload。局部位段常量为 `P_LSB=L`、`N_LSB=2*L`、`DATA_LSB=2*L+P`。context、类型、valid 和物理修补标志单独保存。

插入 E3 锁存 `{payload,n,p,old_head}`，同时读取 NEXT[p]；无前驱时不读 NEXT。E4 直接使用该同步返回补齐 successor（无前驱则使用 old_head），形成 `{payload,n,p,successor}`，并在公共许可下原子写入 DATA[n]、NEXT[n]、metadata、bank/count/cache。没有在 E4 前额外增加完整描述符寄存一级。重复键的 p 来自 TT 尾指针；新代小标签找不到同代前驱时，p 取旧代 bank tail。

插入 E4 将最终描述符写入对应 pending 槽；E5 根据 p.valid 修补 NEXT[p]；E6 写回完成才清 pending valid 并释放上下文。`patch_pending` 在 E5 清除，但逻辑旁路继续有效到 E6。新请求 E5 可复用工作快照，不能覆盖旧 pending。出队 E0 保存旧头并预取 next-head 的 DATA/NEXT，E1 用同步返回直接更新 cache、释放旧节点并生成响应，E2 写回完成。

两个上下文的提交、清除使用位掩码合并，支持旧插入 E6 写回完成与新出队 E1 提交发生在同一沿。busy 根据完整上下文 valid 计算，不用元数据或资源的单个 active 代替。逻辑队列非空但无在途事务且无响应时，busy=0、idle=1 符合规格。

### 8.2 NEXT 旁路与统一故障门控

NEXT 读旁路在读请求采样沿捕获，遵循新逻辑提交、匹配的 pending 写、同沿物理写、RAM 的优先级。合法 FAST5 排程至多有一个尚需对外可见的 pending 前驱写；两个上下文用于重叠写回与新事务。若两项 pending 同时匹配同一个读地址，报调度错误，不按 context 编号猜测新旧顺序。

`wfq_resource_ctrl` 汇总自身及 metadata/list/context 的沿前事件，选择最小非零 fault code，并用同一个 `cycle_allow` 抑制全部正常写入和提交。各检查器使用原始意图，不依赖最终 write_en；顶层不会把 gated commit_fire 接回 commit_req。元数据已经报错而撤销 pred_valid 时，链表不再用派生的“前驱缺失”code=6 覆盖原始 code=7。

较宽指针在缩窄为 RAM 地址之前检查。NULL link 的 ptr 位无语义：valid=0 时不做指针范围检查，语义比较只比较 valid；两个 NULL 即使 ptr 不同也相等。fault 后保留首次编码和已提交响应，禁止新接受及在途修改；已有响应仍可消费。恢复通过复位和完整初始化。

### 8.3 验证入口与下一阶段

```powershell
py -3 -B scripts/run_stage4.py
```

完整第四阶段回归包含 6 项仿真、11 项配置拒绝检查：四组独立稳定排序模型对拍（每组随机段 15,000 周期），以及默认/较宽指针两组全域故障与运行中复位测试。`--quick` 将随机段缩至每组 1,000 周期，保留满容量定向序列和故障测试。日志、结果及源文件 SHA256 写入 `build/stage4/`；合法配置必须在 `-g2001 -Wall` 下无 warning。

具体数值、检查边界和故障场景见 `verification/RTL_Stage4_Report.md`。顶层周期测试已验证持续合格条件下聚合吞吐为 `f_clk/5`；均衡插入/出队各为 `f_clk/10`。这里的 f_clk 是待实现目标时钟，没有综合或 STA 得到的频率数值。

第五阶段按用户最新要求补齐 FAST5 功能验收与长随机；本轮不执行目标综合或 STA。PIPE6 保持未实现，不能从 FAST5 仿真推导 PIPE6 或实际 MHz 结果。

## 9. 阶段 5：FAST5 功能验收与长随机

新增 `tb/tb_wfq_engine_acceptance.v` 与 `scripts/run_stage5.py`。验收 testbench 延续稳定有序数组参考模型，增加接受序号关联、每个节点的 FREE/预留/live 所有权、逐沿全部 RAM 读地址/使能、输入握手保持检查及联合覆盖记录；保留阶段 4 的独立测试文件和历史报告。

入口：

```powershell
py -3 -B scripts/run_stage5.py --jobs 4
```

默认运行五组定向验收、两种 1024 槽配置各十个种子的长随机、八组合法参数顶层运行、两组小容量有界穷举仿真、两组故障/复位，以及前三阶段完整组件回归。每个长随机种子以接受 100,000 次操作为结束条件，结束后完成已有请求并排空队列及响应。该随机接受数不含末尾排空，不用激励周期数代替。

运行结果和联合覆盖表位于 `build/stage5/`。日志按配置/种子区分；源文件 SHA256、参数、随机种子、实际接受数和仿真器版本随结果保存。`--resume` 只复用输入源文件、参数、plusargs、工具版本及日志哈希全部匹配的已完成仿真，并重新检查其 PASS 和接受目标。

`--suite directed|long|parameters|bounded|faults|components` 可单独运行子集；`--accepted`、`--seeds` 仅用于开发缩短或扩展随机量。缩短运行会保留实际规模，不能标记为正式长随机验收。独立 `parameters` 和 `bounded` 子集不代表最终默认容量验收。

F26 显式运行全部 28 种连续 2/3/4 操作模式，检查每个相邻接受恰隔五拍。F28/F29 补齐 bit0/bit15、无效候选和精确叶/备用叶不同的连续操作；F19 明确断言删除最后键后的同地址重用。F31 对每个默认节点地址验证至少两次分配。定向请求源在等待 ready 时也保持 valid/字段，不使用提前撤销请求消除背压。

逐项证据入口和覆盖编码见 `verification/RTL_Stage5_Acceptance_Matrix.md`。小容量穷举仿真覆盖代表性四操作有限输入域，不替代求解器形式证明。F25 仍因 PIPE6 未实现而暂缓；F30 综合/STA 按用户要求排除，所有频率结论仍限于周期吞吐关系。
