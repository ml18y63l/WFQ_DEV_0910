# WFQ Tag Sort Engine — Testcase 清单

> 基线：`Design_Spec_V1.2.md`（FAST5，ISSUE_INTERVAL=5，Verilog-2001）
> 整理日期：2026-09-17。来源：`tb/`（16 个自检查 testbench）、`scripts/run_stage1~5.py`（5 级回归）、`model/`（Python 规格检查模型）、`verification/RTL_Stage*_Report.md`。
> 判定方式：所有 testbench 均以 `PASS <tb名>` / `FAIL <...>` 打印自检结果，回归脚本要求显式 PASS 且不允许任何 FAIL 或编译警告。

---

## 0. 总览

| 层级 | 内容 | 数量 |
| :--- | :--- | :--- |
| Stage 1 | 单元级：复位、RAM、Trie 寄存器、初始化、Matcher | 14 次仿真 + 8 组负向细化 |
| Stage 2 | 元数据子系统集成：TT/RC/NEXT 更新 + 故障原子性 | 9 次仿真 |
| Stage 3 | 资源控制：准入、空闲栈、响应 FIFO、资源调度 + 故障 | 14 次仿真 |
| Stage 4 | 全引擎：tag sort engine 端到端 + 全引擎故障注入 | 6 次仿真 |
| Stage 5 | 验收：directed / long_random / parameters / bounded / faults | 37 次仿真 + 16 组负向细化 |
| 检查模型 | Python 规格级检查（非 RTL 回归，`py -3 model/*.py`） | 5 个 |
| cocotb | Stage 5 long 组的黑盒 cocotb 版本（`verification/cocotb/`） | 20 次仿真 |
| 合计 | RTL 回归仿真 | **100 次**（80 Verilog + 20 cocotb）+ 24 组负向参数检查 |

---

## 1. Stage 1 — 单元级回归（`scripts/run_stage1.py`）

`--quick` 仅跳过 matcher16 穷举。每次编译均带 `-Wall` 且不允许警告。

| Testcase | 参数组合 | 测试内容 |
| :--- | :--- | :--- |
| `tb_wfq_reset_sync` | 默认 | 两级复位同步器：多轮 assert/release，逐拍核对 `core_rstn` 释放时序 |
| `tb_wfq_trie_upper_regs` | 默认 | Trie 上层寄存器文件行为（读/写/清 marker） |
| `tb_wfq_sync_ram` | DATA_WIDTH=10/11/16/37 | 同步 RAM（1r1w 与 1rw）读写周期、延迟与数据保持 |
| `tb_wfq_init_ctrl` | (PTR,DEPTH)=(4,16),(5,16),(10,1024),(11,1024),(11,2048),(12,4096),(16,65536) | 初始化扫描：guard 边界、首次读地址、全部写清除、完成握手 |
| `tb_wfq_matcher16` | 默认（quick 跳过） | 16 路近邻匹配器穷举：LE/LT/MAX 三模式 × 全部 bitmap × query，独立行为参考模型对拍 |
| 负向细化 ×8 | (3,16),(4,32),(9,1024),(10,2048),(10,1000),(10,8),(17,1024),(16,131072) | 非法 PTR_WIDTH/MEM_DEPTH 必须被参数保护拒绝（诊断信息 `wfq_error_invalid_node_capacity_or_pointer_width`） |

## 2. Stage 2 — 元数据子系统集成（`scripts/run_stage2.py`）

| Testcase | 参数组合 | 测试内容 |
| :--- | :--- | :--- |
| `tb_wfq_metadata_update` | (4,16),(10,1024),(11,1024),(16,65536) | 元数据（TT/RC/NEXT）基础更新操作与读回对拍 |
| `tb_wfq_key_metadata` | (4,16) RANDOM_OPS=200/1000；(10,1024) FULL_SWEEP=1 RANDOM_OPS=2000；(11,1024) RANDOM_OPS=200/1000 | 集成元数据验证：独立 live-slot 模型对拍；FULL_SWEEP 全标签扫描；随机插入/删除/查询流；Trie/键/引用计数/路径检查 |
| `tb_wfq_metadata_faults` | (10,1024),(5,16) | 元数据故障原子性：注错后镜像对比（save_image/check_image）、取消-复位、无别名污染 |

## 3. Stage 3 — 资源控制回归（`scripts/run_stage3.py`）

| Testcase | 参数组合 | 测试内容 |
| :--- | :--- | :--- |
| `tb_wfq_admission_ctrl` | 默认 | 准入 RR 仲裁：提案轮转、最小间隔 5、冲突编码（code 6）、复位后冲突偏向 extract、聚合频率 f/5 与分类 f/10 |
| `tb_wfq_free_slot_stack` | (4,16),(10,1024),(11,1024),(16,65536) | 空闲槽栈：push/pop LIFO、满/空边界、地址不重不漏 |
| `tb_wfq_response_fifo` | FLOW_ID_WIDTH=8/9/12 | 响应 FIFO 记分板：E0 接受/预留、E1 生产、最早 E2 消费的注册延迟；保守信用；停止生产后旧 payload 排空；同拍同时事件；拒绝路径；复位丢弃残留 |
| `tb_wfq_resource_ctrl` | (4,16,8,seed12345),(10,1024,9,seed12345),(10,1024,9,seed5381),(11,1024,12,seed67891)；RANDOM_CYCLES=30000（quick 2000） | 独立事务/资源记分板：随机流量下的接受/响应计数、gap=5、冲突、epoch 阻塞、信用阻塞、稀疏间隙；链表行为作为 TB 夹具 |
| `tb_wfq_resource_faults` | (10,1024),(5,16) | 资源控制故障：注错、取消（cancellation）、快照 unchanged 检查、读写抑制 |

## 4. Stage 4 — 全引擎回归（`scripts/run_stage4.py`）

| Testcase | 参数组合 | 测试内容 |
| :--- | :--- | :--- |
| `tb_wfq_tag_sort_engine` | (4,16,8,s12345),(10,1024,9,s12345),(10,1024,9,s5381),(11,1024,12,s67891)；RANDOM_CYCLES=15000（quick 1000） | 端到端稳定有序数组模型 + 全逻辑链表 + 元数据记分板：随机操作流，核对排序输出、gap=5、RAW 冒险（raw）、重叠（overlaps）、双上下文（contexts2）、四类路径计数 |
| `tb_wfq_engine_faults` | (10,1024),(11,1024) | 全引擎故障原子性：对比全部存储器与架构寄存器；E4/E5/E6 插入前、E1/E2 出队前复位；无幽灵提交/响应；重新初始化后可完成新事务 |

## 5. Stage 5 — 验收回归（`scripts/run_stage5.py`）

顶层 `tb_wfq_engine_acceptance`（实例化真实完整顶层，不用 TB 代替提交/链表/资源控制），套件可选用 `--suite all|directed|long|parameters|bounded|faults|components`，默认并行 4 任务、支持 `--resume` 断点续跑。

| 组 | Testcase 配置 | 运行模式 / 内容 |
| :--- | :--- | :--- |
| directed ×5 | (4,16,8),(5,16,9),(5,32,12),(10,1024,9),(11,1024,12) | RUN_MODE=0 定向场景（对应验收矩阵 F01–F22、F26–F29、F31 等，见 §6） |
| long ×20 | (10,9) 与 (11,12) × 10 个独立种子 | RUN_MODE=1 `long_random`：每种子 ≥100,000 次接受操作；8 种分布（均匀/热点/同值/递增/递减/0-4095 极值交错/少量前缀/分散前缀）；变化请求比例、间隙、响应背压、两代/第三代请求；终局要求 accepts=commits=2×responses 且全部地址归还 FREE；覆盖率记录于 `build/stage5/coverage.csv` |
| parameters ×8 | 在 directed 5 组上增加 (11,2048,8),(12,4096,9),(16,65536,12) | RUN_MODE=2 `parameter_smoke`：合法参数展开冒烟（对应 F33） |
| bounded ×2 | (4,16),(5,32) | RUN_MODE=3 `bounded_enumeration`：小容量有界枚举全部操作序列 trace |
| faults ×2 | (10,1024),(11,1024) | `tb_wfq_engine_faults`：真实 RAM/寄存器/返回有效位/归属位注错（code 1~7、同沿最小编码、首次 sticky、同沿写抑制、旧响应可消费，对应 F23/F24/F32） |
| 负向细化 ×16 | ISSUE_INTERVAL=4/6；非法 PTR/DEPTH ×9；FLOW_ID_WIDTH=7/13；TAG_WIDTH=11、EPOCH_WIDTH=15、LITERAL_WIDTH=3 | 非法参数必须细化失败并给出指定诊断串（对应 F33） |

另有 `components` 套件复跑 Stage1–4 已有 case 作为组件级证据（结果写入 `results_components.json`）。

### cocotb 版 long 组（`verification/cocotb/`，黑盒端口级）

| Testcase | 配置 | 运行模式 / 内容 |
| :--- | :--- | :--- |
| `cocotb_long_random` ×20 | (10,1024,9) 与 (11,1024,12) × 10 种子（与 `run_stage5.py` SEEDS 相同） | 等价 RUN_MODE=1 的 cocotb 重实现：Python 稳定排序参考模型全对拍、响应流逐拍核对、commit 脉冲时序（insert=+4/extract=+1）、gap≥5、queue_level/empty/full/busy/idle/epoch 背压逐拍一致性、初始化屏蔽、终局不变量。激励复刻 8 种分布与比例变化，随机流为 Python PRNG（轨迹不同，分布相同）。入口：`make`（单次）或 `python run_long.py`（全量 2×10，CMD 用 `py -3`） |

与 Verilog 版差异：cocotb 版为黑盒（不访问 `u_dut.*` 内部层次，不做 Trie/TT/RC 镜像与逐拍 RAM 调度核对），作为独立补充验证；两套并行维护。详见 `verification/cocotb/README.md`。

### tb_wfq_engine_acceptance 内部测试组

- `directed`：定向插入/出队序列，覆盖极值 tag、重复键 FCFS、Trie 前驱/备用叶（F06–F12）、epoch 回绕与 bank 轮换（F13–F15）、背压与满容量（F16–F21）、RAW/E5 修补（F22）、LIFO 地址重用（F19）等
- `operation_combinations`：2/3/4 操作组合各 4/8/16 种共 28 种，每个相邻接受恰隔 5 拍（F26）
- `long_random`：长随机（见上表）
- `parameter_smoke`：参数展开冒烟（F33）
- `bounded_enumeration`：有界枚举
- 公共检查：每次提交后全 live 链表与稳定有序数组一致性（F02）、分区/元数据/端口级对拍（`check_partition/check_metadata/check_list`）

## 6. Stage 5 验收项 F01–F34（摘要）

完整对应关系见 [RTL_Stage5_Acceptance_Matrix.md](../RTL_Stage5_Acceptance_Matrix.md)。F01–F34 中：

- **F01–F22、F26–F29、F31–F34**：已由 acceptance directed/long/bounded/faults 及参数展开覆盖
- **F25（PIPE6 两配置等价）**：暂缓 —— PIPE6 尚未实现，不得计为 PASS
- **F30（综合/STA）**：暂缓 —— 按要求不执行综合与 STA

## 7. Python 规格检查模型（`model/`，非 RTL 回归）

| 脚本 | 用途 |
| :--- | :--- |
| `wfq_spec_review_check.py` | Design_Spec_V1.md 声明的独立复核（规格评审 2026-09-11，固定种子） |
| `wfq_v11_check.py` | V1.1 规格检查：II=5/6、FF read-0、单口 L3 read-1 的周期/算法模型 |
| `wfq_v12_check.py` | V1.2 容量/指针契约与周期检查（复用 V1.1 周期引擎，增加有限位宽/范围检查） |
| `wfq_ii4_feasibility_check.py` | II=4 可行性模型（提议架构，非 V1.2 RTL；512×4-bit 组合叶最大值摘要） |
| `wfq_trie_single_copy_check.py` | 单副本 Trie 调度检查（提议架构，非冻结 V1 规格） |

## 8. 附注

- cocotb 环境冒烟（`readme_cocotb_installation.md` Step 4 的加法器 smoke test）属环境级验证，位于仓库外临时目录，不计入本项目 testcase；仓库内的 cocotb 测试见 §5 的 cocotb 版 long 组。
- 各 Stage 完整结果与统计：`verification/RTL_Stage1~4_Report.md`、`build/stage*/results.json`；cocotb long 组结果：`verification/cocotb/build/results_long.json`。
- 本清单为静态整理，新增测试后请同步更新。
