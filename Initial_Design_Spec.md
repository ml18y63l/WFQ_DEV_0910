
---

## 1. 概述与设计目标 (Overview & Scope)

### 1.1 设计背景
在高速 IP 网络 QoS 调度中，WFQ（Weighted Fair Queuing）需要按数据包的“虚拟完成时间标签（Finishing Tag）”从小到大严格排序并输出。本模块采用 **Multi-bit Trie 树 + 地址转换表 (Translation Table) + 单向链表存储管理器 (Singly Linked-List Tag Storage Manager)** 的全硬件流水线结构，实现：
- **定制化微架构**: 移除 1.2.1 参考论文提及的 Shared Packet Buffer、Packet Buffer Write Control、Packet Buffer Read Control 模块。将 Finishing Tag Computation Block 输出的 **FTag & Flow_ID** 作为本模块的输入信号。
- **$O(1)$ 的最小标签出队**：最小标签始终位于链表头部，单拍即可读出。
- **确定性时延的标签插入**：任意标签的查找、匹配、链表插入在**固定时钟周期数**内完成（全芯片统一采用 Read Latency = 1 的同步 Block RAM / SRAM）。
- **严格支持重复标签**：通过先来先服务（FCFS）原则在链表中按序串接，并通过引用计数器（Reference Counter）保证元数据一致性。
- **多事务流水线**：为了高性能高吞吐，**Multi-bit Trie 树 + 地址转换表 (Translation Table) + 单向链表存储管理器 (Singly Linked-List Tag Storage Manager)** 支持重叠查找、分配、读写与提交。

### 1.2 参考材料（Reference）
#### 1.2.1 论文（Paper）
- Fully_hardware_based_WFQ_architecture_for_high-speed_QoS_packet_scheduling.md
- A_Scalable_Packet_Sorting_Circuit_for_High_Speed_WFQ_Packet_Scheduling.md
- Design_and_Analysis_of_Matching_Circuit_Architectures_for_a_Closest_Match_Lookup.md
#### 1.2.2 笔记（Notes）
- finishing_tag_range_wraparound.md
- tag_refcount_array.md


### 1.3 核心规格参数
- **标签位宽 (`TAG_WIDTH`)**：`12-bit`（数值范围 $0 \sim 4095$）。
- **Trie 树级数 (`LEVELS`)**：`3 级`（Level 1 至 Level 3）。
- **每级 Literal 位宽 (`LITERAL_WIDTH`)**：`4-bit`（$12\text{-bit} = 3 \times 4\text{-bit}$ 切片）。
- **节点分支因子 (`BRANCHING_FACTOR`)**：`16`（对应 16-bit 节点位图）。
- **匹配电路 (Matcher)**：基于 **Select & Look-Ahead** 加速的近邻匹配电路。
- **在途标签容量 (`MEM_DEPTH`)**：`4096`（`PTR_WIDTH = 12-bit`）。
- **流标识位宽 (`FLOW_ID_WIDTH`)**：`9-bit`（支持 512 个并发数据流 QoS 调度）。
- **设计目标主频**：250MHz ~ 300MHz（基于 14/16nm ASIC 工艺，需经 STA 验证；FPGA 评估频点 125MHz ~ 150MHz）。

---


## 2. 关键参数与常量定义 (Parameters & Generics)

| 参数名 | 默认值 | 范围 | 说明 |
| :--- | :--- | :--- | :--- |
| `TAG_WIDTH` | 12 | 12 | 标签总位宽 |
| `LEVELS` | 3 | 3 | Trie 树的层级数 |
| `LITERAL_WIDTH` | 4 | 4 | 每一级的 Literal 切片宽度（TAG_WIDTH / LEVELS） |
| `BRANCHING_FACTOR`| 16 | 16 | $2^{\text{LITERAL\_WIDTH}}$ |
| `PTR_WIDTH` | 12 | 12~16 | 链表物理地址指针宽度（4096 深度） |
| `FLOW_ID_WIDTH` | 9 | 8~12 | 传入的数据流标识符位宽 |
| `MEM_DEPTH` | 4096 | $2^{\text{PTR\_WIDTH}}$ | Tag Storage Memory 物理存储深度 |

---
## 3. 顶层接口定义 (Interface Declaration)
以下顶层模块的接口信号仅作为参考。按照 Spec 功能要求，进行必要的修改。

```verilog
module wfq_tag_sort_engine #(
    parameter TAG_WIDTH       = 12,
    parameter LITERAL_WIDTH   = 4,
    parameter PTR_WIDTH       = 12,
    parameter FLOW_ID_WIDTH   = 9
)(
    input  wire                          clk,                 // Target: 300MHz (ASIC) / 150MHz (FPGA)
    input  wire                          rstn,

    // ---- 标签插入接口 (Ingress Tag) ----
    input  wire                          insert_val,
    input  wire [TAG_WIDTH-1:0]          insert_tag,
    input  wire [FLOW_ID_WIDTH-1:0]      insert_flow_id,
    output wire                          insert_ready,        // 高电平表示可接收新标签

    // ---- 最小标签弹出/查询接口 (Egress Dequeue) ----
    input  wire                          extract_req,         // 请求读出并移除当前最小标签
    output reg                           extract_val,         // 读出数据有效标志
    output reg  [TAG_WIDTH-1:0]          min_tag_out,         // 最小完成标签 (F_min)
    output reg  [FLOW_ID_WIDTH-1:0]      min_tag_flow_id,     // 对应的流标识
    output wire                          empty                // 内部无在途标签
);
```
---