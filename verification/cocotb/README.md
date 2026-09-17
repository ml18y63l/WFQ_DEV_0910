# cocotb 版 Stage 5 "long" 长随机回归

`tb/tb_wfq_engine_acceptance.v` RUN_MODE=1（`scripts/run_stage5.py --suite long`）的 cocotb
端口级等价实现：对真实顶层 `wfq_tag_sort_engine` 施加长随机插入/出队流量，用 Python
稳定排序参考模型做全对拍。新增cocotb能力同时保持与既有 Verilog 回归相互独立。

## 文件

| 文件 | 说明 |
| :--- | :--- |
| `Makefile` | cocotb + Icarus 构建入口，`PTR_WIDTH/MEM_DEPTH/FLOW_ID_WIDTH/SEED/TARGET` 可参数化 |
| `test_long_random.py` | 测试主体：激励生成 + 记分板 + 协议检查（黑盒，仅访问顶层端口） |
| `run_long.py` | 20 次运行驱动：2 配置 × 10 种子，等价 `run_stage5.py --suite long` |

## 运行

```bash
# 先激活环境（见 ../../readme_cocotb_installation.md）
source /k/AI_Coding/tools/activate_rtl_env.sh

# 单次运行（默认 PTR=10 DEPTH=1024 FLOW=9 SEED=12345 TARGET=100000）
cd verification/cocotb && make

# 快速单次
make SEED=5381 TARGET=5000

# 完整 long 套件（2 配置 × 10 种子，与 run_stage5 SEEDS 相同）
python run_long.py                # 全量 target=100000（CMD 用 py -3）
python run_long.py --quick        # target=5000 快检
python run_long.py --jobs 4       # 并行 4 个仿真（每个独立 SIM_BUILD）
```

日志与汇总：`build/<run>.log`、`build/results_long.json`。

## 与 Verilog 版 long_random 的对应关系

- 激励完全复刻：8 种 tag 分布每 2000 次接受轮换（均匀 / mod8 热点 / 常量 2047 / 递增 /
  递减 / 0-4095 交替 / 0x230 前缀簇 / 三前缀）、epoch 窗口压力（head / +1 / +2 / 64 选 1）、
  nq>96 与 burst<96 的插入/出队比例变化、每 23 拍轮换一次响应背压、
  offer 在被接受前保持稳定不撤销。
- 终局流程一致：random → finish_offers（补完在途 offer，不撤销任何 valid）→ drain
  → 要求 accepts == commits == 2×responses、队列排空、idle。
- 随机数流：使用 Python `random.Random(seed)`，与 Verilog `$random` 序列不同
  （分布逻辑相同，轨迹不同，属于补充覆盖而非逐拍复现）。

## 端口级检查项（记分板）

- 参考模型：按 (epoch, tag, 接受序号) 稳定排序，重复键 FCFS 尾插；
  提交（而非接受）时更新模型，与 `queue_level` 逐拍一致。
- 响应流：`extract_val` 有效时 `(min_epoch_out, min_tag_out, min_tag_flow_id)`
  必须等于模型队头且保持稳定；消费顺序 FIFO 对拍。
- commit 脉冲精确时序：insert = 接受 +4 拍、extract = 接受 +1 拍，不多不少。
- 协议：相邻接受间隔 ≥5（gap5 计数）；每拍至多一个接受；
  `insert_epoch_blocked` 语义（epoch ∉ {head, head+1} 且非空）逐拍核对。
- 状态一致性：`queue_level/empty/full/busy/idle/fault` 全部与模型逐拍核对
  （full = 无空闲槽 = live+已接受未提交；busy = E0..WB 窗口；idle = 无上下文无响应）。
- 初始化：屏蔽检查（无 ready/val/busy/idle/full）与
  边沿计数（DEPTH≤8192 时 8192+3）断言。
- 全程 fault==0；看门狗：随机进度、held offer 完成、drain 终止。

## 与 Verilog 版的差异（已知且有意为之）

- 黑盒 vs 白盒：Verilog TB 另外逐拍核对 Trie/TT/RC/L3 全镜像、每拍 RAM 读写调度、
  FREE 栈分区覆盖、覆盖率元组（coverage.csv）。这些深度白盒检查不在 cocotb 版范围内，
  由既有 Verilog 回归继续承担；cocotb 版提供独立的端口级端到端对拍。
- 断言深度：cocotb 版以响应流与状态端口为主，不访问 `u_dut.*` 内部层次。

## 规模参考（2026-09-17 实测，i7 级桌面 CPU）

单次 100000 接受操作 ≈ 54 万仿真周期 / 约 620 万项记分板检查 / 78 秒（Icarus 14 +
cocotb 2.1，每周期 2 次触发回调）。全量 20 次（`--jobs 4`）约 8 分钟，累计约
1.24 亿项检查；gap5 占比 ≈ 96.8%（绝大多数接受都以最小间隔 5 拍发出）、
峰值占用 ≈ 116/1024。
