# VCS tag 回绕定向测试

用例：`tb_wfq_tag_wrap.v`，基于 `Design_Spec_V1.2.md` §3/§4/§10。
测试和 DUT 均使用 Verilog-2001，不使用 SystemVerilog/UVM。
参数固定为 `PTR_WIDTH=10`、`MEM_DEPTH=1024`、`FLOW_ID_WIDTH=9`、`ISSUE_INTERVAL=5`。

## 覆盖范围和期望结果

每组先交错插入旧、新两代共 8 项，再保持第三代插入请求，出队旧代后允许第三代自动进入，最终全部排空。

| 场景 | 逻辑 epoch | 接口 16-bit epoch | 检查点 |
| --- | --- | --- | --- |
| 1 | 7 → 8 → 9 | 7 → 8 → 9 | tag 4095→0；旧代大 tag 优先于新代小 tag |
| 2 | 65535 → 65536 → 65537 | 65535 → 0 → 1 | tag 和 epoch 同时回绕，不能直接无符号比较 `{epoch,tag}` |

设旧代为 E，两组使用相同输入顺序：

| 插入序号 | 逻辑 epoch | tag（十进制） | flow_id |
| --- | --- | --- | --- |
| 1 | E | 4095 | 91 |
| 2 | E+1 | 0 | 81 |
| 3 | E | 4094 | 71 |
| 4 | E+1 | 1 | 61 |
| 5 | E | 4095 | 51 |
| 6 | E+1 | 0 | 41 |
| 7 | E | 4080 | 31 |
| 8 | E+1 | 4095 | 21 |
| 9 | E+2 | 0 | 11 |

每组响应的 `flow_id` 顺序必须为 **31、71、91、51、81、41、61、21、11**；scoreboard 同时逐项比较 epoch、tag 和 flow_id。

- 使用未截断的整数逻辑 epoch 建模，仅驱动/比较接口时截断为 16 bit，参考模型不复制 DUT 的 bank 排序实现。
- 相同 `{epoch,tag}` 按接受顺序出队，特意使用递减 flow_id 区分 FCFS 与错误的 flow_id 排序。
- 同代 tag 下降、相邻代交错到达、两代相同 tag 均合法。
- 第三代保持 valid 和 payload 不变；旧代尚未排空时必须 `insert_epoch_blocked=1`、`insert_ready=0`，合法出队仍须推进。
- 旧代排空后，无复位接受第三代并复用 bank；第一组完全排空后直接以 epoch 65535 重建窗口。
- 每组第一次出队时暂停消费响应，检查 valid/payload 保持，并覆盖至少 10 个背压采样沿。
- 检查插入 E0+4、出队 E0+1 提交、提交口径的 `queue_level/empty`、无 fault、接受间隔不小于 5 拍且确实出现 5 拍间隔。
- 最后确认 18 次插入、18 次出队、18 个响应以及写回/响应全部完成；全局 20000 拍超时捕获死锁。此用例是回绕功能定向测试，不替代完整吞吐或容量验收。

## Linux VCS + Verdi 运行

需先完成所在环境的 VCS/Verdi 安装、license 和动态库配置。使用与 VCS 匹配的 64-bit FSDB PLI。

```bash
export VERDI_HOME=/path/to/verdi
# vcs 不在 PATH 时指定可执行文件：
# export VCS=/path/to/vcs/bin/vcs
bash verification/vcs_sim/run_vcs.sh
```

脚本可从任意工作目录用绝对路径调用。默认 PLI 位于 `$VERDI_HOME/share/PLI/VCS/LINUX64`（也支持 `NOVAS_HOME`）。若现场安装布局不同，显式指定包含 `novas.tab` 和 `pli.a` 的目录：

```bash
export FSDB_PLI_DIR=/path/to/compatible/PLI/VCS/LINUX64
OUT_DIR=/absolute/path/to/run_tag_wrap bash verification/vcs_sim/run_vcs.sh
```

默认输出在仓库的 `build/vcs_sim/tag_wrap/`，已受根目录 `.gitignore` 忽略：

- `compile.log`：VCS 编译日志。
- `sim.log`：插入、输出、覆盖计数和最终 PASS/FAIL。
- `wfq_tag_wrap.fsdb`：从复位开始记录顶层与 DUT 下全部层级，使用 `+all` 包括存储数组。
- `simv`、`simv.daidir/`、`csrc/`：仿真产物。

VCS 运行脚本始终定义 `FSDB` 并链接 PLI；仿真结束先刷新 FSDB。脚本同时检查仿真退出码、PASS/FAIL 文本和非空波形文件，避免 Verilog `$finish` 返回 0 时误判通过。复跑同一输出目录会替换上一轮的日志/波形；保留多轮结果请设置不同 `OUT_DIR`。

```bash
verdi -ssf build/vcs_sim/tag_wrap/wfq_tag_wrap.fsdb
```

建议查看 `scenario`、输入/输出握手及 payload、`insert_epoch_blocked`、`queue_level`、commit、fault；调试窗口推进时可展开 `u_dut.base_epoch`、`bank0_epoch/bank1_epoch`、`bank0_count/bank1_count`。scoreboard 仅依赖公开端口。

## 验证边界

本地可用 Icarus 以 `-g2001 -Wall` 编译同一测试并运行功能检查（不定义 `FSDB`）。该检查不能替代实际 VCS/Verdi 的 PLI 链接和 FSDB 生成验收。当前工作不涉及综合或 STA。

2026-09-23 本地验证结果：严格 Verilog-2001 编译无警告，两个场景全部通过；每组 9 次插入、9 个响应、35 个 epoch 背压采样沿、11 个响应背压采样沿、15 次 5 拍接受间隔。Bash 脚本语法检查通过。当前机器没有 VCS/Verdi，尚未实际生成 FSDB。

```text
PASS tb_wfq_tag_wrap scenarios=2 inserts=18 extracts=18 responses=18 gap5=30
```
