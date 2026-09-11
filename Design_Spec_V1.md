# wfq_tag_sort_engine — Design Specification V1

| 项目 | 内容 |
| :--- | :--- |
| 文档版本 | V1.0 |
| 日期 | 2026-09-11 |
| 设计对象 | `wfq_tag_sort_engine` |
| 文档用途 | RTL 微架构、接口集成、验证及综合约束的设计基线 |
| 起点 | [Initial_Design_Spec.md](Initial_Design_Spec.md) |
| 状态 | 规格基线；尚未完成 RTL、仿真、综合或 STA |
| 已确认的接口决策 | 增加显式 epoch 输入，支持回绕前后标签同时驻留 |

本文中“必须”表示 V1 的实现和验收要求；“建议”表示可在保持外部行为的前提下调整的实现方式。文中明确选定的周期数、存储端口及 epoch 组织属于本项目的工程设计决策，并非参考论文已经验证的本项目指标。

## 1. 目标、范围与参考资料

### 1.1 功能目标

模块接收 `{epoch, finishing_tag, flow_id}` 描述符，在片内维护稳定有序队列，并按请求输出及移除当前最小项。

必须实现：

1. 同一 epoch 内，按 12-bit 无符号 finishing tag 升序排列。
2. 支持相邻两个 epoch 共存；旧 epoch 的所有项排在新 epoch 之前。
3. 相同 `{epoch, tag}` 按插入握手先后顺序服务，即 FCFS。
4. 使用 Multi-bit Trie、Translation Table、单向有序链表和空闲地址管理器。
5. 默认最多保存 4096 个描述符，支持 512 个 Flow ID；重复标签也分别占用物理槽位。
6. 所有 RAM 使用同步读、Read Latency = 1；不依赖器件未定义的同址读写行为。
7. 已接受请求有固定的处理时延；处理时延不随驻留项数、标签稀疏程度及重复次数变化。
8. 支持前一事务写回与后一事务查找、分配或预读重叠，保证后者看到前者的完整逻辑结果。

### 1.2 模块边界

输入的 finishing tag 已由外部 Finishing Tag Computation Block 计算、量化并附加 epoch。本模块不计算权重、虚拟时间、包长除法、start tag 或 finishing tag。

不包含 Shared Packet Buffer、Packet Buffer Write Control、Packet Buffer Read Control，也不保存包内容和包缓冲区地址。输出 Flow ID 由外部用于定位该流待服务的数据包。系统集成方必须保证流内描述符与实际包队列对应；若需要区分同流内任意包，应另行增加 packet ID/payload pointer，这不属于 V1 接口。

当外部通过 Flow ID 弹出逐流 FIFO 的头包时，同流的逻辑 finishing tag 必须按包进入该 FIFO 的顺序非递减，使描述符出队顺序与包顺序一致。本模块把 Flow ID 当作不透明数据，不检查这一外部集成约束。

本模块是标签排序器。完整 WFQ 公平性仍取决于外部 tag 计算、包队列管理和服务时机。V1 不承诺单独实现 WF²Q 的 eligibility 判断。

### 1.3 本地参考资料

| 编号 | 文件及相关章节 | 本设计使用内容 |
| :--- | :--- | :--- |
| R0 | [初始草稿](Initial_Design_Spec.md) | 模块范围、参数、总体架构和初始接口 |
| R1 | [A Scalable Packet Sorting Circuit](Paper_in_Markdown/A_Scalable_Packet_Sorting_Circuit.md)，III-A～III-D | 三级 Trie、备用搜索路径、TT、链表、重复标签 |
| R2 | [Fully Hardware Based WFQ Architecture](Paper_in_Markdown/Fully%20hardware%20based%20WFQ%20architecture.md)，3.1、3.2 | 与 tag 计算模块的边界、FCFS、系统架构 |
| R3 | [Design and Analysis of Matching Circuit](Paper_in_Markdown/Design_and_Analysis_of_Matching_Circuit.md)，3.1、3.2.4 | Select & Look-Ahead matcher |
| N1 | [tag_refcount_array](Paper_in_Markdown/Important_Notes/tag_refcount_array.md) | 重复标签计数、最后一项删除、陈旧 TT 指针风险 |
| N2 | [finishing_tag_range_wraparound](Paper_in_Markdown/Important_Notes/finishing_tag_range_wraparound.md) | 有限 tag 范围、回绕时旧/新标签共存问题 |

以上使用的是目录中给出的 Markdown 内容。部分论文表格、图片和公式在转录文件中不完整；本文不以这些转录的性能数字作为本 RTL 的验收结果。

### 1.4 对草稿及笔记的补充和修正

| 事项 | V1 决定 |
| :--- | :--- |
| 12-bit 标签回绕 | 增加 16-bit epoch；两个 metadata bank 对应相邻两代，维持一条全局有序链表 |
| 引用计数位宽 | `clog2(MEM_DEPTH+1)`，默认 **13 bit**；12 bit 不能表示 4096 |
| “单拍最小值” | 通过完整链表头缓存，出队握手后 1 拍产生响应；后续输出停顿由背压决定 |
| 固定插入时延 | 接受后 7 拍逻辑提交，9 拍完成物理退休；见第 10 节 |
| 多事务流水 | 共享发射间隔 8 拍，最多两个事务处于执行/写回区间；第 10～11 节给出重叠和转发规则 |
| RAM 延迟及端口 | 统一同步读 1 拍；明确复制数量和每周期端口预算，不能从“dual port”推断任意多读多写 |
| 备用路径 | 对三个互斥的前驱候选类并行求值，不使用可变次数回溯 |
| 无前驱 | 支持任意新最小标签；不依赖 R1 中“新标签总不小于当前最小值”的系统假设 |
| 删除策略 | refcount 归零时精确清除叶、父、根；不按 tag 数值跨段粗略清树 |
| NULL 指针 | `{valid, ptr}`，不占用任何物理地址；地址 0 和 4095 都可使用 |
| 出队接口 | 增加请求 ready、响应 ready、提交脉冲，响应可背压 |
| 同拍插入/出队 | 共享发射器仲裁，只接受一个；不隐式实现同拍换入换出 |

8 拍发射间隔是 V1 的确定性基线。它以端口可实现和一致性可证明为前提，不等价于论文中的 4 拍 tag storage 操作，也不宣称每拍插入、每拍出队。缩短间隔需要重新设计依赖处理、端口安排并更新规格。

## 2. 参数、常量与数据定义

### 2.1 参数表

| 名称 | 默认值 | V1 支持范围/约束 |
| :--- | ---: | :--- |
| `TAG_WIDTH` | 12 | 固定为 12 |
| `LITERAL_WIDTH` | 4 | 固定为 4 |
| `LEVELS` | 3 | 派生为 `TAG_WIDTH/LITERAL_WIDTH`，必须为 3 |
| `BRANCHING_FACTOR` | 16 | 派生为 `1 << LITERAL_WIDTH` |
| `EPOCH_WIDTH` | 16 | V1 固定为 16 |
| `EPOCH_BANKS` | 2 | 固定为 2 |
| `PTR_WIDTH` | 12 | 支持 4～16 |
| `MEM_DEPTH` | 4096 | 必须等于 `2**PTR_WIDTH`，RTL elaboration 时检查 |
| `FLOW_ID_WIDTH` | 9 | 支持 8～12 |
| `COUNT_WIDTH` | 13 | 派生为 `$clog2(MEM_DEPTH+1)` |
| `TAG_VALUES` | 4096 | 派生为 `2**TAG_WIDTH` |
| `ISSUE_INTERVAL` | 8 | V1 固定为 8 |
| `INSERT_COMMIT_LATENCY` | 7 | V1 固定为 7 |
| `INSERT_RETIRE_LATENCY` | 9 | V1 固定为 9 |
| `EXTRACT_COMMIT_LATENCY` | 1 | V1 固定为 1 |
| `EXTRACT_RETIRE_LATENCY` | 2 | V1 固定为 2 |
| `RSP_DEPTH` | 2 | 两项寄存器响应 FIFO |
| `MAX_INFLIGHT` | 2 | 执行及尚未退休的写回事务总数上限，不计已退休的输出响应 |

`MEM_DEPTH` 是所有 epoch、所有 Flow ID 共享的总容量，不是每个 bank 的容量。metadata 表的深度由 tag 范围决定，与物理槽位数独立。

### 2.2 基本类型

~~~systemverilog
typedef logic [TAG_WIDTH-1:0]     tag_t;
typedef logic [EPOCH_WIDTH-1:0]   epoch_t;
typedef logic [PTR_WIDTH-1:0]     ptr_t;
typedef logic [FLOW_ID_WIDTH-1:0] flow_id_t;
typedef logic [COUNT_WIDTH-1:0]   count_t;

typedef struct packed {
    logic valid;
    ptr_t ptr;
} link_t;

typedef struct packed {
    epoch_t   epoch;
    tag_t     tag;
    flow_id_t flow_id;
} payload_t;
~~~

`link_t.valid=0` 表示 NULL，此时 ptr 不参与寻址。任何计数的合法范围为 `0..MEM_DEPTH`；禁止使用指针位宽保存容量计数。`flow_id` 是不透明的随路数据，不作为同值标签的第二排序键。

### 2.3 地址格式和位序

对 `tag = {a,b,c}`：

~~~text
a = tag[11:8]       // 最高 4 bit
b = tag[7:4]
c = tag[3:0]        // 最低 4 bit
bank = epoch[0]

L1_addr = bank
L2_addr = {bank, a}
L3_addr = {bank, a, b}
TT_addr = RC_addr = {bank, tag}
~~~

节点位图 bit i 对应 literal i。bit 15 是最大 literal，bit 0 是最小 literal。文档、RTL、波形和验证模型必须统一该位序。

## 3. 排序语义与 epoch 协议

### 3.1 有效排序键

同一调度窗口中的排序顺序为：

~~~text
(epoch 的逻辑先后, tag 的无符号大小, 插入接受顺序)
~~~

不直接对 `{epoch,tag}` 进行无符号大小比较，因为 epoch 本身也允许模回绕。插入接受顺序不要求存入每个节点；通过按序提交和 TT 指向同值尾部实现。

本模块只保证每次出队的是该请求之前已接受插入形成的队列中的最小项。若外部在一次出队之后再插入更小 tag，整个历史输出序列可以下降，这不构成错误。

### 3.2 epoch 的生成责任

上游必须在完整 finishing tag 从一代进入下一代时，将该条描述符的 epoch 加 1，低 12 bit 作为 tag。epoch 属于每条描述符，不是根据相邻输入 tag 是否变小而产生的全局翻转脉冲。

例：不同流依次产生 `{5,1000}`、`{5,20}` 不代表回绕；`{5,4095}` 和 `{6,10}` 则属于不同代。允许这两代的描述符交错到达，前提是两代仍处于当前合法窗口。

### 3.3 当前窗口与 bank 生命周期

维护 `base_epoch`，表示当前非空队列中最旧的 epoch；`next_epoch = base_epoch + 1`，按 16 bit 截断。

1. 队列非空时，只接受 `insert_epoch == base_epoch` 或 `insert_epoch == next_epoch`。
2. 相邻 epoch 的最低位不同，分别使用两个 bank；每个 bank 保存自己的完整 `bank_epoch` 和有效标志。
3. 当前代清空且下一代仍有节点时，在该次出队提交时将 `base_epoch` 推进到下一代。
4. 释放后的 bank 的所有 RC、TT valid 和 Trie marker 必须已由精确删除归零，才能供再下一代使用；不启动额外清表过程。
5. 队列完全为空、且允许发射新请求时，第一条插入可使用任意 epoch，并重新建立 base。尚未消费的出队响应不阻碍 bank 重用，响应中保存完整 epoch。
6. 空队列后的重新建窗是新的驻留窗口；上游仍负责避免把已经过期的历史描述符作为新业务再次发送。
7. V1 同时支持两代，不能同时保存三代。第三代请求背压，直到最旧一代排空后窗口推进。

输入属于过去代或超前两代以上时，`insert_ready=0` 且 `insert_epoch_blocked=1`。它是未接受的请求，不改变任何状态。若超前请求一直保持 valid，合法出队仍可获得发射机会，使窗口继续推进。

### 3.4 回绕示例

| 按此顺序插入 | 最终出队顺序 |
| :--- | :--- |
| `{7,4090,A}`、`{8,10,B}`、`{7,4095,C}`、`{8,0,D}` | `{7,4090,A}` → `{7,4095,C}` → `{8,0,D}` → `{8,10,B}` |
| `{65535,4095,A}`、`{0,0,B}` | A → B；epoch 的数值 0 不会被判为更旧 |
| `{9,10,A}`、`{10,10,B}` | A → B；RC 和 TT 分别位于不同 bank |
| 当前有 epoch 9、10，输入 epoch 11 | 不接受；epoch 9 清空并推进 base 后可接受 |

不能仅靠清除旧小 tag marker 解决排序回绕。marker 的可重用性和服务先后是两个问题；本规格通过 epoch 窗口明确解决后者。[N2]

## 4. 顶层接口与握手

### 4.1 建议的规范接口

~~~systemverilog
module wfq_tag_sort_engine #(
    parameter int TAG_WIDTH     = 12,
    parameter int LITERAL_WIDTH = 4,
    parameter int EPOCH_WIDTH   = 16,
    parameter int PTR_WIDTH     = 12,
    parameter int MEM_DEPTH     = (1 << PTR_WIDTH),
    parameter int FLOW_ID_WIDTH = 9,
    parameter int COUNT_WIDTH  = $clog2(MEM_DEPTH + 1)
) (
    input  logic                      clk,
    input  logic                      rstn,

    input  logic                      insert_val,
    output logic                      insert_ready,
    input  logic [EPOCH_WIDTH-1:0]     insert_epoch,
    input  logic [TAG_WIDTH-1:0]       insert_tag,
    input  logic [FLOW_ID_WIDTH-1:0]   insert_flow_id,
    output logic                      insert_commit,
    output logic                      insert_epoch_blocked,

    input  logic                      extract_req,
    output logic                      extract_ready,
    output logic                      extract_commit,
    output logic                      extract_val,
    input  logic                      extract_out_ready,
    output logic [EPOCH_WIDTH-1:0]     min_epoch_out,
    output logic [TAG_WIDTH-1:0]       min_tag_out,
    output logic [FLOW_ID_WIDTH-1:0]   min_tag_flow_id,

    output logic                      init_done,
    output logic                      empty,
    output logic                      full,
    output logic [COUNT_WIDTH-1:0]     queue_level,
    output logic                      busy,
    output logic                      idle,
    output logic                      fault,
    output logic [3:0]                fault_code
);
~~~

派生参数即使出现在参数列表中，也必须通过 elaboration 断言禁止不一致覆盖。

### 4.2 接受条件

~~~text
insert_fire  = insert_val  && insert_ready
extract_fire = extract_req && extract_ready
rsp_fire     = extract_val && extract_out_ready
~~~

请求在 clk 上升沿握手。插入端在 valid 且未 ready 时必须保持 valid、epoch、tag 和 flow_id；出队请求端必须保持 extract_req 到握手成功。`extract_req` 持续为 1 表示希望持续出队，每次握手产生一个独立请求。

模块只在空闲发射时刻对可接受请求给出 grant/ready；ready 可以依赖两端的 valid、仲裁状态和资源条件。请求方不得等待 ready 才拉高 valid。

每次发射只允许一个 `insert_fire` 或 `extract_fire`。一旦接受，在随后 7 个上升沿禁止再接受请求，第 8 个上升沿起重新可发射；若没有合格请求，保持可发射直到下一次接受，无须空等额外的 8 拍周期。

### 4.3 仲裁

合法插入候选：初始化完成、无 fault、可发射、至少有一个可分配地址、epoch 合法。

合法出队候选：初始化完成、无 fault、可发射、`queue_level>0`、响应 FIFO 有可预留位置。

两者同时有效时采用 round-robin；复位后首次冲突优先出队。每次接受后，将下一次冲突优先级让给另一类。只有一类合格时立即选择该类，资源不合格的请求不能占住仲裁器。

满队列时不能因同拍存在 extract_req 就接受插入；先接受出队，后续发射时再接受插入。空队列同时请求插入和出队时，只接受插入；其提交前不能出队。

### 4.4 响应和背压

`extract_val` 是响应 FIFO 头的 valid，不是单周期脉冲。为 1 且 `extract_out_ready=0` 时，必须保持 valid 和三个输出数据不变。

每个 extract_fire：

1. 当拍预留一个响应位置。
2. 下一拍执行出队逻辑提交、拉高一拍 extract_commit，并将响应放入 FIFO。
3. 若 FIFO 原为空，下一拍之后 extract_val 和数据即有效；若已有响应，则按请求顺序排队。
4. 消费响应仅释放 FIFO 项，不再次删除链表节点、不再次释放地址。

`RSP_DEPTH=2`，接收条件保守使用 `rsp_count + rsp_reserved < 2`；不把当拍可能发生的 rsp_fire 预支为容量，允许有一个边界气泡。FIFO 必须支持同拍出队和生产响应。

“出队 1 拍”的保证是请求接受到响应进入 FIFO 的时间；输出最终被下游消费的时间受背压和更早响应影响，没有固定上界。

### 4.5 状态输出

| 信号 | 定义 |
| :--- | :--- |
| `queue_level` | 已逻辑提交且尚未出队提交的节点数，不含待提交插入和响应 FIFO |
| `empty` | init_done 时等于 `queue_level==0` |
| `full` | init_done 时等于 `free_count==0`，包含插入已预留但未提交的槽位 |
| `insert_commit` | 每个接受的插入在第 7 拍产生一次提交脉冲 |
| `extract_commit` | 每个接受的出队在第 1 拍产生一次提交脉冲，与响应入 FIFO 同时 |
| `busy` | 有已接受但尚未物理退休的事务，包括写回事务 |
| `idle` | `init_done && !fault && !busy && rsp_count==0 && rsp_reserved==0`；不要求数据队列为空 |
| `insert_epoch_blocked` | `init_done && insert_val && !epoch_legal`，独立于发射和仲裁 grant |
| `fault` | 内部检测到不可恢复一致性错误后的粘滞状态 |

插入已接受但未提交时，empty 可以仍为 1；同时 free_count 已减少。empty 不代替 extract_ready，full 不代替 insert_ready。输出数据只在 extract_val 为 1 时有意义。

## 5. 微架构

### 5.1 结构图

~~~mermaid
flowchart LR
    I["Insert: epoch / tag / flow"] --> A["Admission + round-robin"]
    E["Extract request"] --> A
    A --> P["Fixed schedule / transaction context"]
    P --> T["Two epoch banks: 3-level Trie + matchers"]
    T --> TT["Translation Table: tail pointer"]
    P --> RC["Tag reference counts"]
    TT --> L["Singly linked sorted list: DATA + NEXT"]
    P --> F["Free address stack"]
    F --> L
    L --> H["Global head cache"]
    H --> Q["Reserved response FIFO"]
    Q --> O["epoch / tag / flow"]
    P --> C["Atomic logical commit + writeback forwarding"]
    C --> T
    C --> TT
    C --> RC
    C --> L
    C --> H
~~~

### 5.2 子模块职责

| 建议模块名 | 职责 |
| :--- | :--- |
| `wfq_tag_sort_engine.sv` | 顶层连接、接口状态、参数检查 |
| `wfq_admission_ctrl.sv` | 发射间隔、RR、容量/epoch/响应预留检查 |
| `wfq_epoch_ctrl.sv` | base/next、bank 标识、两代窗口推进 |
| `wfq_trie_search.sv` | 三类候选路径、固定时延前驱查找 |
| `wfq_matcher16.sv` | 16-bit Select & Look-Ahead，LE/LT/MAX |
| `wfq_translation_table.sv` | 标签到同值尾节点的地址转换 |
| `wfq_tag_refcount_array.sv` | 每 bank、每 tag 的引用计数 |
| `wfq_list_manager.sv` | 插入点、head/tail、链路修改和头缓存 |
| `wfq_free_slot_stack.sv` | 物理地址分配与释放 |
| `wfq_commit_ctrl.sv` | 构造提交描述符、逻辑提交、写回退休 |
| `wfq_sync_ram_1r1w.sv` | 同步存储包装、同址旁路和读有效信号 |
| `wfq_response_fifo.sv` | 两项响应 FIFO、预留和背压 |
| `wfq_init_ctrl.sv` | 顺序初始化、端口接管和 ready 开放 |

模块可合并或拆分，但不能改变规定的状态归属、访问预算和握手语义。

### 5.3 全局与每 bank 状态

全局状态至少包含：`queue_level`、`free_count`、`alloc_reserved`、`head`、`tail`、`head_cache`、`base_epoch`、发射冷却计数器、RR 状态、事务 valid、writeback valid 和响应计数。

每个 bank 至少包含：

- `bank_valid`、完整 `bank_epoch`、`bank_count`。
- `bank_head`、`bank_tail`、`bank_min_tag`、`bank_max_tag`。
- 对应的 L1/L2/L3、TT 和 RC 存储内容。

非空 bank 在全局链表中是连续区段：旧代区段之后连接新代区段。全局 head 是最旧非空 bank 的 head，global tail 是最新非空 bank 的 tail。

`head_cache` 保存 `{head.ptr, payload, next}` 的完整记录。每次逻辑提交必须同时更新或修补缓存，确保下次出队不需要先读当前头节点。缓存 next 的一致性与缓存 tag 的一致性同样重要。

## 6. 存储组织与端口预算

### 6.1 RAM 资源表

深度已包含两个 epoch bank。1R1W 表示每拍一个同步读和一个同步写，不表示两个任意读写端口。

| RAM | 逻辑深度 × 宽度（默认） | 物理副本 | 有效端口 | 内容 |
| :--- | :--- | ---: | :--- | :--- |
| L1 | 2 × 16 | 1 | 1R1W | 根位图 |
| L2 | 32 × 16 | 2 | 2R1W | 两个独立读副本，写广播 |
| L3 | 512 × 16 | 3 | 3R1W | 三个独立读副本，写广播 |
| TT | 8192 × 13 | 1 | 1R1W | `{valid, tail_ptr}` |
| RC | 8192 × 13 | 1 | 1R1W | 默认 0～4096 |
| DATA | 4096 × 37 | 1 | 1R1W | `{epoch[15:0],tag[11:0],flow_id[8:0]}` |
| NEXT | 4096 × 13 | 1 | 1R1W | `{next_valid,next_ptr}` |
| FREE | 4096 × 12 | 1 | 1R1W | 空闲指针栈 |

L1/L2 即使映射为触发器或 FPGA distributed RAM，也必须通过寄存的读取接口保持 1 拍契约，不可让下游依赖组合读。

分离 DATA 和 NEXT，使前驱指针修补不需要重写 epoch、tag、flow_id，也避免完整描述符的 read-modify-write 扩大冲突范围。

### 6.2 占用估算

默认配置纯 RAM 数据位数：

~~~text
Trie = 2*16 + 2*(32*16) + 3*(512*16) = 25,632 bit
TT   = 8192*13                      = 106,496 bit
RC   = 8192*13                      = 106,496 bit
DATA = 4096*37                      = 151,552 bit
NEXT = 4096*13                      = 53,248 bit
FREE = 4096*12                      = 49,152 bit
总计                                 492,576 bit ≈ 60.13 KiB
~~~

不包含头缓存、bank 状态、响应 FIFO、事务/写回寄存器、ECC、宏填充和 FPGA BRAM 的粒度浪费。每 bank 原始 Trie 仍是 `16+256+4096=4368 bit`；上述更大数值包含双 bank 和为固定时延备用搜索增加的读副本。

### 6.3 同步读和同址读写

统一时序约定：

- 读请求的 enable/address 在上升沿 `E_k` 采样；RAM q 在随后周期稳定，下一级在 `E_(k+1)` 捕获使用。
- 写请求在 `E_k` 生效；写回控制器仍保留足够长的转发信息，覆盖同沿已发出的读请求。
- 一个同步 RAM 的 q 后不能再额外插入未计入预算的输出寄存器；若器件宏强制多一拍，必须调整整个时序规格。

包装器必须对每个读请求一起寄存 bypass_hit/bypass_data，并随该次读返回使用。逻辑优先级：

~~~text
本沿新提交的写集合 > 尚未退休的已提交写集合（最新优先） > RAM q
~~~

禁止依赖 FPGA 的 read-first/write-first/no-change 默认模式。副本写入相同地址、相同数据，读侧转发也必须覆盖所有副本。

### 6.4 空闲地址栈

FREE 初始化为 `FREE[i]=i`，`free_count=MEM_DEPTH`。所有物理地址均可分配；默认第一次分配地址 4095。

插入接受沿：

1. 以旧 `free_count-1` 读取 FREE。
2. `free_count--`，`alloc_reserved++`。
3. 下一拍捕获分配地址，归该事务独占。

插入提交时仅将预留槽位变为 live：`alloc_reserved--`、`queue_level++`。

出队提交时，将原 head.ptr 写入 `FREE[free_count]`，`free_count++`、`queue_level--`。出队后的节点 DATA/NEXT 无须清零，但不能再被任何有效链路或 TT 引用。

栈读取地址和容量运算必须先用 COUNT_WIDTH 计算并检查合法，再截取 PTR_WIDTH 作为地址。禁止在 free_count=0 时下溢读取。

始终满足：

~~~text
free_count + alloc_reserved + queue_level == MEM_DEPTH
~~~

响应 FIFO 已保存完整描述符，因此出队槽位可在逻辑出队提交时释放，不必等待下游消费响应。

## 7. Trie、Matcher 和前驱查找

### 7.1 Trie 的精确定义

对任意 bank、a、b、c，逻辑提交后的视图必须满足：

~~~text
L3[bank,a,b][c] == (RC[bank,{a,b,c}] != 0)
L2[bank,a][b]   == OR(L3[bank,a,b])
L1[bank][a]     == OR(L2[bank,a])
~~~

Trie 表示“某个键是否至少有一个节点”，不表示节点个数。TT 和 RC 同时以 `{bank,tag}` 寻址，不能只使用 tag。

### 7.2 Matcher 功能契约

`wfq_matcher16` 为组合逻辑，其输出在所属流水级边界寄存。输入为 `bitmap[15:0]`、`query[3:0]`、mode，输出至少包含 `found`、`index[3:0]`、`onehot[15:0]`、`exact`。

| mode | 数学定义 |
| :--- | :--- |
| LE | 最大的 i，使 `bitmap[i]=1 && i<=query` |
| LT | 最大的 i，使 `bitmap[i]=1 && i<query` |
| MAX | 最大的 i，使 `bitmap[i]=1` |

无解时 `found=0`、onehot=0、index=0、exact=0。index=0 不表示命中，必须结合 found。exact 仅在 LE 模式且选中 query 时为 1。

先构造候选位图 C：

~~~text
LE:  C[i] = bitmap[i] && (i <= query)
LT:  C[i] = bitmap[i] && (i <  query)
MAX: C[i] = bitmap[i]
~~~

query=0 的 LT 候选必须全零；query=15 的 LE 必须包含 bit 15。推荐逐位 generate 构造掩码，避免 16-bit 左移 16、无符号减一或无尺寸常数引起边界错误。

### 7.3 Select & Look-Ahead 实现约束

采用 4 组 × 4 bit，每组并行求非空和组内最大候选，Result Control 并行选择最高非空组：

~~~text
G[g] = OR(C[4*g +: 4])
S[g] = G[g] AND NOT(OR(G[3:g+1]))
local_onehot[g][j] =
    C[4*g+j] AND NOT(OR(C[4*g+3:4*g+j+1]))
onehot[4*g+j] = S[g] AND local_onehot[g][j]
~~~

空范围的 OR 定义为 0。组间选择和组内候选并行计算，最后进行选择及编码，符合 Select & Look-Ahead 的分块预计算思想。[R3]

不使用 16 个串联“未命中则再找下一位”的跨全字 ripple 链作为目标实现。行为模型可以用循环求最大值，但综合 RTL 应显式表达分组并行关系；最终速度以所选标准单元/FPGA 的时序报告为准。

### 7.4 固定时延前驱：三个候选类

对新 tag `x={a,b,c}`，只在它所属 epoch 的 Trie 查找：

~~~text
P_same = max { y | y <= x 且该 epoch 中 RC[y] > 0 }
~~~

所有可能的 y 可分为以下三个互斥的类，优先级严格为 A > B > C：

| 类别 | 前缀规则 | 求值 |
| :--- | :--- | :--- |
| A | `y[11:4] == {a,b}` | 对 `L3[a,b]` 执行 LE(c) |
| B | `y[11:8] == a, y[7:4] < b` | `bB=LT(L2[a],b)`，随后 `cB=MAX(L3[a,bB])` |
| C | `y[11:8] < a` | `aC=LT(L1,a)`，`bC=MAX(L2[aC])`，`cC=MAX(L3[aC,bC])` |

先同时读 L2[a] 和 L2[aC]，再同时读三个 L3 候选节点，因此较低层无候选时无需重新发起父层访问：

- A 命中则返回 A，包含 exact match。
- A 未命中且 B 命中则返回 B。
- A、B 均未命中且 C 命中则返回 C。
- 三者都未命中则 `pred_same_valid=0`。

候选有效性必须包含路径上父 marker 和 matcher found。无效地址可以驱动 0，但必须关闭 read enable 或忽略结果，不能把地址 0 的真实内容当成备选命中。

A 的 L3 读取同时获得新 tag 所在叶节点的旧值，用于插入更新；L2[a] 的读取也同时用于维护。每层的副本数量已在第 6 节计入。

这三个类穷尽 `y<=x` 的字典序可能性，所以固定三层查找足以处理稀疏树，不依赖概率分布或“总有较小值”的假设。

### 7.5 从同代前驱到全局前驱

1. 若 pred_same_valid，读 `TT[bank,pred_same_tag]`，取其 tail_ptr 为全局前驱。
2. 若无同代前驱，而插入属于下一代且旧代非空，取 `bank_tail[old]` 为全局前驱。
3. 否则没有全局前驱，插入全局 head 之前。

第二种情况是跨 epoch 排序的关键：新代的小 tag 接在旧代尾之后，不能成为全局 head。

例如旧代有 tag 4095，新代有 tag 10，插入新代 tag 0 时，前驱是旧代 tag 4095 的尾节点。修改后为旧 4095 → 新 0 → 新 10。

### 7.6 精确 marker 更新

插入时，旧 RC 为 0：

~~~text
new_leaf   = old_leaf | (1 << c)
new_parent = old_parent | (1 << b)
new_root   = old_root | (1 << a)
~~~

若旧 RC 大于 0，只更新 RC 和 TT，不改变 Trie。

出队时，旧 RC 为 1：

~~~text
new_leaf = old_leaf & ~(1 << c)
new_parent = old_parent
if new_leaf == 0:
    new_parent = old_parent & ~(1 << b)
new_root = old_root
if new_parent == 0:
    new_root = old_root & ~(1 << a)
~~~

按 new_leaf/new_parent 判断，而不是按旧值判断。所有 mask 明确定义为 16 bit。同代同 tag 仍有剩余项时，禁止清 marker、禁止作废 TT。

## 8. Translation Table 与引用计数

### 8.1 TT 的语义

`TT[bank,tag]` 始终指向该键的**最后一个 live 节点**，不是第一个节点，也不是最小物理地址节点：

~~~text
TT.valid == (RC != 0)
TT.valid -> DATA[TT.tail_ptr].{epoch,tag} == 对应的完整键
~~~

每次插入该键，无论此前是否存在，提交时都令 `TT={1,new_ptr}`。最后一项出队时写 `TT={0,0}`。

### 8.2 RC 的语义和边界

`RC[bank,tag]` 等于逻辑链表中该键的节点数：

~~~text
0 <= RC <= MEM_DEPTH
sum(RC[全部 bank 和 tag]) == queue_level
~~~

4096 个相同键同时驻留时，RC=4096，必须能表示 `13'b1_0000_0000_0000`。N1 中的“4096×12-bit 计数 RAM”不适用于草稿的满容量同值输入，V1 已修正。

RC 读改写依据该事务看到的已提交视图。对尚未提交插入不提前置 marker 或更新 TT，否则后继查找可能拿到尚未初始化的节点。

### 8.3 状态转移表

| 操作 | 旧 RC | 新 RC | TT | Trie |
| :--- | :--- | :--- | :--- | :--- |
| Insert | 0 | 1 | valid=1，tail=new_ptr | 对应路径置位 |
| Insert | 1..MEM_DEPTH-1 | old+1 | tail=new_ptr | 保持 |
| Extract | >1 | old-1 | 保持 | 保持 |
| Extract | 1 | 0 | valid=0 | 精确清叶；必要时清父、根 |
| Insert | MEM_DEPTH | 不允许 | 不修改 | 容量不变量应已阻止接受 |
| Extract | 0 | 内部 fault | 禁止部分提交 | 指示状态损坏 |

V1 每次只执行一个逻辑队列操作，因此没有同拍 Insert/Extract RC 合并算术。时间相邻的同键事务仍必须通过提交顺序和读写转发正确串接。

## 9. 链表操作与头缓存

### 9.1 有序链表基本不变量

逻辑视图中：

- queue_level=0 当且仅当 head.valid=tail.valid=0。
- 非空时从 head 开始沿 NEXT 恰好访问 queue_level 个互异节点，最后到 tail，且 tail.next.valid=0。
- 每个 live 节点属于且只属于一个 bank 区段，键满足第 3 节顺序。
- 所有 live 指针与 FREE 有效栈区间、在途预留地址互斥。
- 地址分配顺序不影响排序顺序。

### 9.2 插入操作

设新节点地址为 n，全局前驱为 p，插入前全局头为 h：

~~~text
若 p 有效：
    successor = NEXT[p]
    DATA[n]   = incoming_payload
    NEXT[n]   = successor
    NEXT[p]   = {valid=1, ptr=n}
否则：
    DATA[n]   = incoming_payload
    NEXT[n]   = h
    head      = {valid=1, ptr=n}
~~~

successor 无效时更新 global tail=n。原队列为空时，head=tail=n，NEXT[n] 无效。

更新本 bank：

- 原 bank 为空：bank_head=bank_tail=n，bank_min_tag=bank_max_tag=tag，并建立 bank_epoch。
- tag < bank_min_tag：bank_head=n，bank_min_tag=tag。
- tag >= bank_max_tag：bank_tail=n，bank_max_tag=tag；相同最大 tag 的新节点是新的同值尾部。
- 其余情况只增加 bank_count。

更新 head_cache：

- 若新节点成为全局 head，缓存新 payload 和 successor。
- 否则若前驱 p 等于当前全局 head.ptr，必须把缓存 next 改为 n。
- 其他情况保持缓存。

所有指针、TT、RC、Trie、head/tail、bank 状态和 queue_level 在同一逻辑提交点生效。物理 NEXT 的两次写入可以跨两拍，但期间必须由写回转发提供完整逻辑视图。

### 9.3 重复 tag 与 FCFS

例：按顺序插入 `{e,10,A}`、`{e,15,C}`、`{e,10,B}`：

~~~text
链表：10_A -> 10_B -> 15_C
TT[e,10] = addr(10_B)
RC[e,10] = 2
~~~

出队 10_A 后 RC 从 2 变为 1，TT 仍指向 10_B。再插入 10_D 必须接到 10_B 后。只有最后一个 tag 10 节点离开时才清理其 TT 和 marker。

### 9.4 出队操作

接受沿从 head_cache 捕获旧头节点 h 的 payload 和 next：

1. 若 h.next 有效，以其地址并行读取 DATA 和 NEXT，预取下一头的完整缓存。
2. 同时用 h 的 bank/tag 直接读取 RC、L1、L2 精确节点、L3 精确节点；无需遍历 Trie。
3. 下一拍原子执行：
   - 将 h 的 payload 放入已预留的响应 FIFO。
   - head 更新为 h.next；若有下一头，用读回值形成 head_cache。
   - 原 head 所属 bank_count 减 1，更新其 bank_head 和最小 tag；若该 bank 清空，作废它的 head/tail 及 valid。
   - RC 减 1；若归零，同步作废 TT 并精确清 marker。
   - 将 h.ptr 归还 FREE。
   - queue_level 减 1；必要时清 global tail 或推进 base_epoch。

出队只删除全局 head，不需要查找前驱或重写 NEXT 链。只要全局仍非空，global tail 保持不变。

### 9.5 单节点、跨 bank 和缓存边界

| 场景 | 必须行为 |
| :--- | :--- |
| 唯一节点出队 | head/tail/cache valid 清零，bank 清空，RC/TT/Trie 清零，地址释放 |
| 同键有多节点 | 头推进到下一节点，TT 保持同值尾，marker 保持 |
| 旧代最后一项出队，新代非空 | head 直接推进到新代头，base_epoch 前进，新代节点无需重排 |
| 插入新全局最小值后立即出队 | 头缓存提供新插入项 |
| 在当前 head 后插入后立即出队 | 头缓存 next 必须已修补，推进到新节点 |
| 旧代仅一个节点，向新代头部插入 | 前驱是旧代 head/tail；既修补 RAM NEXT，也修补 head_cache.next |

### 9.6 只读最小值

V1 的 extract 是破坏性出队，不提供独立 peek 接口。最小值通过内部 head_cache 实现常数时间访问；如需把未出队的 F_min 连续反馈给外部 tag 计算模块，应在后续接口版本增加独立的 peek_valid/peek_payload，不能把可能背压的 min_tag_out 当成当前未出队最小值。

## 10. 固定时序、发射和性能

### 10.1 时间术语

以请求接受上升沿为 E0：

- **接受**：握手成功并预留资源。
- **逻辑提交**：该操作对队列状态和后续操作可见；通过提交描述符覆盖尚未写完的 RAM。
- **物理退休**：该操作所有 RAM 写入和相关转发读均已完成，事务上下文可以复用。
- **响应消费**：下游完成 ready/valid 握手，与出队逻辑提交分开。

队列操作按接受顺序提交。插入最晚在下一次可接受请求前一拍提交，所以后一请求不会越过它；不需要回放已接受请求。

### 10.2 插入：逐拍基线

表中“发读”表示在该行上升沿采样地址；上一拍读出的 q 经本周期组合逻辑在当前沿进入下一阶段。

| 上升沿 | 控制/运算 | 存储动作 |
| :--- | :--- | :--- |
| E0 | 接受 payload，校验窗口/容量，预留槽位，启动 8 拍发射间隔 | 读 L1[bank]、RC[bank,tag]、FREE[free_count-1] |
| E1 | 捕获分配地址、旧 RC、根值；选出 C 的 aC | L2 副本 0 读 [bank,a]，副本 1 读 [bank,aC] |
| E2 | 得到 bB、bC，保持旧 L2[a] | L3 三副本分别读 A/B/C 的叶节点 |
| E3 | 对叶执行 LE/MAX，A>B>C 选择；计算 Trie 更新所需新值 | 同代前驱有效时读 TT[bank,pred_tag]，否则使用跨代尾或无前驱 |
| E4 | 得到全局前驱指针及 TT valid | 前驱有效时读 NEXT[p] |
| E5 | 得到 successor；形成新节点、前驱修补、头尾及 bank 更新 | 无强制 RAM 访问 |
| E6 | 对完整写集合、计数边界和前驱有效性做最终检查；锁存 commit descriptor | 无强制 RAM 访问 |
| E7 | **逻辑提交**，insert_commit=1；释放预留计数，更新缓存及状态寄存器 | 写 RC、TT、必要的 L1/L2/L3、DATA[n]、NEXT[n] |
| E8 | 可接受下一事务；继续前驱链路写回 | 若有前驱，写 NEXT[p]；相关读通过 overlay/同址旁路获得新值 |
| E9 | **物理退休**，前驱写回及同沿读旁路信息交接完成 | 释放旧 writeback context |

空树、无前驱和重复标签仍走相同提交时刻，用 valid/enable 屏蔽不需要的 RAM 访问，不提前提交。E5/E6 的寄存阶段用于将链路计算、检查和原子提交扇出分开，不允许默认为组合穿透。

### 10.3 出队：逐拍基线

| 上升沿 | 控制/运算 | 存储动作 |
| :--- | :--- | :--- |
| E0 | 捕获 head_cache，预留响应位置，启动 8 拍发射间隔 | 并行读下一头 DATA/NEXT、旧头 RC/L1/L2/L3 |
| E1 | **逻辑提交**，extract_commit=1；响应入 FIFO，更新 head_cache、bank、base 和计数 | 写 RC、必要的 TT/L1/L2/L3，并写 FREE[旧 free_count] |
| E2 | **物理退休** | 释放出队上下文，响应可继续背压 |
| E8 | 最早接受下一请求 | 按下一事务类型启动访问 |

出队的精确节点地址来自缓存 tag，不依赖 Trie 查找结果，所以 RC、三层维护读取与下一头读取可以在 E0 并行发出。E0～E1 的关键路径包含 RAM q、计数递减、16-bit 零检测/清位以及寄存器建立时间，必须列为 STA 重点。

若无法满足该路径的目标时钟，不得悄悄增加出队周期；应在降低频点或更新接口时延规格后重新验收。

### 10.4 重叠示例

| 全局上升沿 | T0（Insert） | T1（Insert） | T2 |
| :--- | :--- | :--- | :--- |
| 0 | 接受 | — | — |
| 7 | 逻辑提交 | — | — |
| 8 | 最后一次 NEXT 写回 | 接受 | — |
| 9 | 退休 | L2 读取 | — |
| 15 | — | 逻辑提交 | — |
| 16 | — | 最后一次 NEXT 写回 | 最早可接受 |
| 17 | — | 退休 | 执行中 |

精确关系为：T0 在 E0 接受、E7 提交、E8 最后一次 NEXT 写、E9 退休；T1 在全局 E8 接受、E15 提交、E16 最后写、E17 退休。

因此在全局 E8～E9，T1 的查找/分配与 T0 的写回重叠，至少需要两个事务上下文。V1 不承诺多个尚未逻辑提交的插入同时穿过 Trie；这正是本版本能以固定接受后时延处理任意热点键的前提。

若 T1 为出队，它在全局 E8 接受、E9 提交、E10 退休；T0 的旧写回事务在 E9 退休。写回队列必须支持该沿 retire/enqueue 同时发生。

### 10.5 端口峰值检查

| RAM | Insert 的读/写时刻 | Extract 的读/写时刻 |
| :--- | :--- | :--- |
| L1 | R:E0；W:E7 | R:E0；W:E1 |
| L2 两副本 | 各 R:E1；广播 W:E7 | 副本 0 R:E0；广播 W:E1 |
| L3 三副本 | 各 R:E2；广播 W:E7 | 副本 0 R:E0；广播 W:E1 |
| RC | R:E0；W:E7 | R:E0；W:E1 |
| TT | R:E3；W:E7 | 归零时 W:E1 |
| DATA | W:E7 | 下一头 R:E0 |
| NEXT | 前驱 R:E4；新节点 W:E7；前驱 W:E8 | 下一头 R:E0 |
| FREE | R:E0 | W:E1 |

前一插入的最后 NEXT 写与后一出队的 NEXT 读可同拍发生，由 1R1W 加转发覆盖。不存在合法调度要求同一物理副本一拍两写的情况。

### 10.6 吞吐和时钟目标

在容量、epoch、输出信用均满足，且请求持续有效时：

~~~text
聚合请求接受率 = f_clk / 8
均衡插入/出队时，每方向 = f_clk / 16
~~~

| 时钟频率 | 聚合操作率 | 均衡流量每方向/包服务率 |
| :--- | ---: | ---: |
| 125 MHz | 15.625 Mops/s | 7.8125 Mpacket/s |
| 150 MHz | 18.75 Mops/s | 9.375 Mpacket/s |
| 250 MHz | 31.25 Mops/s | 15.625 Mpacket/s |
| 300 MHz | 37.5 Mops/s | 18.75 Mpacket/s |

ASIC 目标为 14/16 nm 下 250～300 MHz，FPGA 评估目标为 125～150 MHz。以上为按发射间隔计算的理论值，频率尚未验证。

一个完整驻留再服务过程消耗一次插入和一次出队，不能把聚合操作率直接称为均衡包服务率。由 Mpacket/s 换算线速必须另给包长及物理链路开销。

握手前等待、初始化、非法/超窗 epoch、满队列、空队列、响应背压不包含在固定处理时延内。持续合格的两类请求在 RR 下最多经历一次另一类接受；若在任意时刻开始等待，最多 15 拍可被接受，前提是等待期间一直保持资源合格。

## 11. 原子提交、转发及并发冲突

### 11.1 提交描述符

每个事务保存完整的待生效改变，至少包含：

- 操作类型、输入 payload 或出队 payload、分配/释放地址。
- 前驱及 successor、旧/新 head、tail、bank 描述符和 base_epoch。
- RC 新值、TT 新值及对应 write enable。
- L1/L2/L3 新值及对应 write enable。
- DATA[n]、NEXT[n]、NEXT[p] 等有效地址/数据。
- 响应预留标识、错误状态、阶段 valid、提交/退休标志。

提交之前这些值属于事务私有状态。提交沿更新全部架构寄存器，并将完整 RAM 写集合加入逻辑 overlay。提交之后，尚未写入 RAM 的新值与已经落入 RAM 的新值具有相同可见性。

### 11.2 逻辑视图

任何参与排序或指针解引用的读必须读取：

~~~text
logical_read(addr) =
    newest_committed_overlay_hit(addr) ? overlay_data : RAM_data
~~~

无效 TT、被清除的 marker 和写为 NULL 的 NEXT 都是有效更新，不能因为“新数据为零”而跳过转发。

默认至多两项 writeback descriptor。前一事务在下一次发射前已经逻辑提交，后一事务无需猜测前一操作是否会成功，也不允许采用“先算，错了再回放”的可变时延方式。

### 11.3 转发生命期

NEXT[p] 在 E8 执行物理写之后，其 overlay 至少保留到 E9。若有 E8 同址读，包装器必须已经捕获它的转发数据；退休不能使该读在下一拍退回到旧 RAM q。

匹配地址必须包含所有 bank 位和完整 RAM 地址。对不同 RAM 的同数值地址不能误旁路。读响应必须携带 read_valid 和事务归属，不能用当前拍地址解释上一拍数据。

### 11.4 冲突处理矩阵

| 相邻事务冲突 | V1 处理 |
| :--- | :--- |
| 两次插入相同键 | 后者读到前者提交后的 marker、RC、TT tail，接在前者后 |
| 不同键共享 L3 叶或 L2 父 | 使用前次提交后的完整位图进行 read-modify-write，不丢失其他 bit |
| 后一插入改变前驱选择区间 | 后一搜索开始于前一逻辑提交之后，重新搜索完整新状态 |
| 前一插入修补后一出队将使用的 next | head_cache 修补加 NEXT 同址转发 |
| 最后同键节点出队后再次插入 | 下一次读取看到 RC=0、TT 无效、marker=0，按首次出现处理 |
| 释放地址随后重新分配 | FREE 只含逻辑已删除地址；下一次发射前旧事务已无未完成的节点写引用 |
| 旧 bank 清空，随后由再下一代重用 | 全部精确元数据已归零，bank_epoch 改为新代，不继承陈旧 TT |
| 满队列同时请求出队/插入 | 本次只出队，下次发射才分配释放的地址 |
| 出队响应长期背压 | FIFO 预留信用用尽后停止接受出队，已有响应保持；合格插入仍可发射 |

### 11.5 指针释放安全

已释放指针不能仍作为未提交插入的前驱：共享发射规则保证出队被接受时不存在更早的未提交插入。

对于前一插入、后一出队的最紧重叠，前一插入最后节点写在全局 E8，后一出队释放地址在 E9。后续事务最早 E16 才能重新分配地址，不存在旧 NEXT 写覆盖重新分配节点的窗口。

这一证明依赖 8 拍发射间隔和明确退休时刻。实现不能只改 ISSUE_INTERVAL 常数以提高吞吐。

## 12. 时钟、复位与初始化

### 12.1 时钟和复位

全部功能、RAM 和接口使用同一个 clk，不包含内部 CDC，不采用 RAM 倍频时钟来暗中增加访问端口。

rstn 为低有效复位，控制寄存器异步置复位、同步释放。建议在顶层使用两级释放同步器；所有内部模块使用统一的内部 reset，禁止各自独立释放导致半初始化状态。

大容量 RAM 不通过异步 reset 或复位分支中的全数组 for 循环清零，以保证 SRAM/BRAM 可推断。控制寄存器、流水 valid、缓存 valid、响应 valid 和 fault 需要复位。

### 12.2 初始化流程

定义：

~~~text
META_DEPTH  = EPOCH_BANKS * TAG_VALUES = 8192
INIT_WRITES = max(META_DEPTH, MEM_DEPTH)
~~~

初始化控制器独占全部 RAM 写端口，计数 i 从 0 到 INIT_WRITES-1：

| 条件 | 同沿写入 |
| :--- | :--- |
| i < 8192 | RC[i]=0，TT[i]={valid=0,ptr=0} |
| i < 2 | L1[i]=0 |
| i < 32 | 所有 L2 副本 [i]=0 |
| i < 512 | 所有 L3 副本 [i]=0 |
| i < MEM_DEPTH | FREE[i]=i |

DATA/NEXT 无须清零，因所有槽位均为空闲且没有有效指针可达。每个新节点必须先由插入完整写入 DATA/NEXT，再通过逻辑提交变为可见。

最后一次初始化写后留一个 guard 边沿，设置 free_count=MEM_DEPTH、queue_level=0、所有 bank/head/tail 无效、init_done=1。下一上升沿才允许第一次请求握手。

以第一个初始化写沿为 R0，最后写沿为 R_(INIT_WRITES-1)，guard 为 R_INIT_WRITES，第一次可能接受为 R_(INIT_WRITES+1)。外部 rstn 的同步释放时间另计。

默认共 8192 个写沿加一个 guard，按 8193 个时钟预算约为 32.772 μs @250 MHz、54.620 μs @150 MHz；这不是每次 epoch 回绕的开销。

### 12.3 初始化期间接口

`insert_ready=extract_ready=0`，`insert_commit=extract_commit=extract_val=0`，`queue_level=0`，`empty=1`，`full=0`，`busy=0`，`idle=0`，`insert_epoch_blocked=0`。

请求方可以保持 valid 等待 init_done 和握手。模块不能在初始化结束后重放初始化期间未握手的脉冲请求。

### 12.4 运行中复位

复位清空所有队列语义，取消未提交事务和未消费响应，重启完整初始化；不承诺保留之前接受的数据。上游与下游必须作为同一复位域协调恢复，不能把复位前握手当作复位后仍待完成的请求。

复位期间必须关闭所有正常运行 RAM 写 enable 和响应生产，防止旧流水 valid 在初始化过程中回写数据。

## 13. 错误和异常行为

### 13.1 正常背压

以下是正常情况，不置 fault：

- 初始化未完成或发射间隔尚未到期。
- 满队列、空队列、响应 FIFO 无预留信用。
- epoch 超出当前两代窗口。
- 两路请求同时有效，某一路本次未获 RR grant。

不接受即不分配、不删除、不改变 RC/TT/Trie、不生产响应。无法从 wire 位宽发现“上游把更宽 tag 错误截成 12 bit”，因此截断及 epoch 生成必须在上游验证。

### 13.2 内部 fail-stop

以下本地可检测错误必须阻止该事务提交并置粘滞 fault；fault_code 锁存首次错误：

| 编码 | 含义及可检测位置 |
| :--- | :--- |
| 0 | 无错误 |
| 1 | RC 下溢或上溢：出队读到 0、插入读到 MEM_DEPTH |
| 2 | Trie 返回有效同代前驱，但读回 TT.valid=0 |
| 3 | 已选中的必要链路/头缓存有效性与计数矛盾，例如非空无 head、多个节点却无 head.next |
| 4 | 活跃 bank_epoch、计数或所读下一头 payload 的 epoch 与预期区段不一致 |
| 5 | 容量/预留或响应信用计数越界 |
| 6 | 写回描述符无可用位置、非法端口冲突或阶段有效性错误 |
| 7～15 | 保留 |

并非要求硬件每拍扫描全表。全链表无环、所有 FREE 地址唯一和全量 RC 总和等全局性质通过验证断言/检查器保证；上述 fault 对应正常数据通路上可实施的局部检查。

fault 后停止新请求和未完成事务的后续提交，保留已经提交的响应 FIFO 供下游消费，等待复位。fault 前已提交状态可能有尚待处理的物理写回；fault 状态不再保证队列可继续服务，恢复必须完整复位初始化。

固定时延和完成保证适用于无复位、无内部 fault、接口协议合法的工作区间。fault 不是正常流量控制机制，不允许通过置 fault 掩盖合法热点流量或正常资源冲突。

### 13.3 外部协议检查

验证环境应断言：

- insert_val 被背压时 payload 和 valid 保持。
- extract_req 被背压时不撤销。
- response 被背压时 DUT 保持 valid 与 payload。
- init_done 之前不出现接受和提交。

除 epoch 窗口明确背压外，本模块不为上游协议违规提供重试或错误响应接口。

## 14. 验证计划与验收标准

### 14.1 独立参考模型

采用软件稳定优先队列或排序列表保存 `{unwrapped_epoch,tag,accept_sequence,flow_id}`：

1. 测试激励在未截断域产生逻辑 epoch，再编码为 16 bit 驱动 DUT，避免参考模型重复 DUT 的 bank 选择错误。
2. 记录每次 insert_fire 的 payload，并在规定的 insert_commit 时刻加入参考队列。
3. 每次 extract_fire 预期下一拍执行删除；在 extract_commit 时，从参考队列删除最小项，加入独立的预期响应 FIFO。
4. 仅在 rsp_fire 时比较 DUT 输出与预期响应 FIFO 头。
5. 每次提交后，比较 queue_level；需要时通过 bind 检查逻辑 overlay 后的链表、RC、TT 和 Trie。

相同 epoch/tag 的 FCFS 依据 insert_fire 的序号，不依据 Flow ID、物理地址或提交脉冲后的软件观察顺序。

检查“当前最小项”时必须允许出队之后新插入更小值，不能简单对整个历史输出做单调性断言。

### 14.2 单元验证

| 单元 | 必测项 |
| :--- | :--- |
| matcher16 | 全部 65536 个 bitmap，对 16 个 query 穷举 LE/LT；MAX 全 bitmap；found/onehot/index/exact 一致 |
| trie search | 与集合上的 max(y<=x) 对比；A/B/C 命中、无前驱、空根、共享前缀和稀疏回退 |
| RC | 0→1、1→0、1→2、MEM_DEPTH-1→MEM_DEPTH、上下溢检测 |
| TT | 首次插入、同值尾更新、非最后出队保持、最后出队清 valid |
| RAM wrapper | 同拍同址/异址读写，overlay 清零，副本一致，退休与读返回相邻 |
| free stack | 全容量分配、释放重分配、地址 0/最大地址、栈空/满边界 |
| response FIFO | 空/满、预留、同拍入出、长期背压、数据稳定 |
| epoch control | 两代共存、推进、16-bit epoch 回绕、第三代背压、完全清空后重建窗口 |

### 14.3 顶层定向用例

| ID | 场景 | 关键结果 |
| :--- | :--- | :--- |
| F01 | 复位、初始化、第一项插入/出队 | 初始化周期准确，首次有效 head，回到空状态 |
| F02 | 同 epoch 任意顺序插入 tag 0、4095 和中间值 | 无符号升序，新最小值和新最大值均正确 |
| F03 | 不同 Flow ID 的相同键反复插入 | 严格 FCFS，TT 始终指同值尾 |
| F04 | 4096 个完全相同的键 | 可满容量，RC=4096，不回绕为 0 |
| F05 | 出队同值组的第一项、中间项、最后项 | 仅最后一项清 marker/TT |
| F06 | 叶被清空但父仍有其他叶；父清空但根仍有其他分支 | 不误清兄弟路径 |
| F07 | 当前树为 {0x1FF,0x250,0x300}，查/插 0x240 | A/B 失败，C 返回 0x1FF |
| F08 | 当前树为 {0x210,0x250}，查/插 0x240 | A 失败，B 返回 0x210 |
| F09 | 当前树为 {0x245,0x249}，查/插 0x247 | A 返回 0x245 |
| F10 | 当前树最小 tag=100，插入 0 | 无前驱，更新全局 head |
| F11 | 在 head 后插入，下次发射立即出队 | 缓存 next 修补正确，无遗漏新节点 |
| F12 | 全局仅一个节点，插入相同或更小 tag，再连续请求出队 | head/tail/cache 和同值顺序正确 |
| F13 | 旧代 4090/4095 与新代 0/10 交错插入 | 旧代全部先服务，bank 内升序 |
| F14 | 相邻两代同数值 tag 同时驻留 | RC、TT 独立，不混为重复键 |
| F15 | epoch=65535→0→1，跨代重用 bank | 顺序正确，无陈旧 marker/TT |
| F16 | 第三代 valid 持续，同时持续出队 | 插入背压，出队不饥饿；窗口推进后接受 |
| F17 | 满时两路请求；空时两路请求 | 一次仅一类握手，容量不预支 |
| F18 | 两路始终 valid 且资源一直允许 | RR 交替，接受间隔 8 拍 |
| F19 | 最后同键节点出队、释放地址后再次插入 | 无野指针、不成环、地址可安全复用 |
| F20 | 下游长期拉低 extract_out_ready | 两个响应位填满后不再接受出队；响应数据保持 |
| F21 | 响应未消费时队列已空，再插入并复用地址/bank | 老响应 payload 不受物理复用影响 |
| F22 | T0 插入在 E8 修补 NEXT，同时 T1 出队读取 NEXT | 覆盖同址旁路/相关头缓存情况，结果与参考模型一致 |
| F23 | E7 提交、E8 写回、E9 退休附近复位 | 无复位后幽灵提交，完整重新初始化 |
| F24 | 故障注入 TT.valid/RC/头缓存矛盾 | fault_code 正确，禁止部分逻辑提交，复位可恢复 |

F22 中应分别构造真正同址与不同址访问的 RAM 单元用例；顶层合法链表可能使某些特定地址相等不可达，不能为追求覆盖而构造非法流量并要求正常服务。

### 14.4 随机验证和覆盖

默认容量下建议至少 10 个独立种子、每个种子 100,000 次已接受操作，并在结尾排空、消费全部响应和核对无剩余预期项。流量组合包含：

- 均匀随机 tag、集中同值、少数热点叶/父、递增、递减和交错极值。
- 单流与多流；同一 Flow ID 的重复 payload 也按实例计数。
- 插入/出队比例偏斜，频繁空满转换，随机请求停顿和响应背压。
- 相邻代交错、epoch 边界、第三代阻塞、bank 多次复用。

功能覆盖至少交叉：操作类型、队列状态、重复/新键、A/B/C/无前驱、bank 角色、位图清除层级、指针等于 head/tail、响应信用状态和相邻事务类型。

对小容量配置（例如 MEM_DEPTH=16/32）运行更多满空转换和有界形式检查；tag 范围仍为 4096。另至少对默认容量完成 F04，不能用小容量代替 13-bit 计数验收。

### 14.5 关键断言

以下为应实现的断言语义；具体 SVA 必须按采样沿和 NBA 可见性编写，不能直接套用文字周期：

1. 每拍 `!(insert_fire && extract_fire)`，相邻 fire 间隔至少 8 拍。
2. 无复位/fault 时，insert_fire 恰好对应第 7 拍一次 insert_commit，extract_fire 恰好对应第 1 拍一次 extract_commit。
3. 不允许无请求提交、重复提交、无预留生产响应；每个提交恰好释放一次预留。
4. `free_count + alloc_reserved + queue_level == MEM_DEPTH`。
5. `sum(bank_count) == queue_level`；每 bank RC 总和等于 bank_count。
6. RC 非零、TT.valid、叶 marker 三者等价，父/根等于子层归约 OR。
7. 所有有效 TT 指针指向 live 的同键尾节点。
8. 链表节点数量、无环、顺序、tail.next=NULL 和地址互斥不变量。
9. head.valid 时，`head_cache == logical_node(head.ptr)`，尤其 next 必须一致；head 无效时缓存也必须无效。
10. `rsp_count + rsp_reserved <= RSP_DEPTH`，背压时输出稳定。
11. 两个活跃 bank 的完整 epoch 必须为 base 与 base+1。
12. 每个物理 RAM 每拍不超过规定端口数；副本写一致。
13. 退休时所有未完成写为零，并且已发出读的转发值已经交接。

全数组/链表断言可放在仿真检查器，形式验证可对小容量实例进行分解。不可为使断言成立而在综合 RTL 内加入全表组合扫描。

### 14.6 完成 RTL V1 的验收门槛

- 通过全部定向用例、规定随机回归和所有已启用断言，无数据丢失、重复、乱序或死锁。
- 按接受沿测得规定提交/退休时刻；无数据相关 replay 或额外周期。
- 合格连续请求达到 8 拍聚合接受间隔；背压用例与协议一致。
- elaboration/lint 无未处理的位宽截断、无符号/有符号混用、组合环或锁存器。
- 综合确认 RAM 推断/宏实例的位宽、端口及读延迟与第 6 节一致。
- 在声明的目标器件/库、约束和工作角下完成 STA，报告实际频点、裕量及关键路径。
- 输出实际寄存器/组合逻辑/RAM 资源，不用本文件位数估计代替综合报告。

以上是后续 RTL 的验收要求，不表示当前文档生成阶段已经执行了这些 RTL 测试。

## 15. RTL 编码与物理实现要求

### 15.1 编码约定

建议使用 SystemVerilog、always_ff/always_comb、packed struct 和显式 localparam。寄存器只有一个时序写入所有者；通过 next-state 或提交仲裁合并初始化与正常写操作。

必须遵守：

- 数值比较明确无符号，epoch 仅做相等和受限 next 关系判断。
- 地址有效性与地址值分离，不用全 1 或全 0 指针作 NULL。
- count 加减先做边界检查，避免窄位中间表达式溢出。
- 默认组合赋值覆盖全部分支；无效 payload 不参与 matcher 或 RAM 地址生成。
- 不使用综合不可接受的动态数组/队列实现硬件链表。
- 不从完整 RC 数组组合计算最小值、root 或 queue_level。
- 不通过异步读 RAM、隐含倍频或增加未声明读副本实现时序表。
- 数据路径寄存器不必全部 reset，但其 valid 必须 reset，且无效数据不可产生写 enable。

### 15.2 时序路径和约束

重点路径：

1. RAM q → matcher 候选/编码 → 下一级 RAM 地址建立。
2. 同步 RAM/overlay → NEXT successor → 提交描述符。
3. 出队 RAM q → 叶/父/根清位及 RC 减法 → E1 写入/缓存更新。
4. overlay 地址比较 → 读旁路选择 → 下一级寄存器。
5. 提交描述符 → 多 RAM write enable/address/data 与 head/bank 状态寄存器。

时钟约束必须包含 RAM 宏模型、输入输出延迟、时钟不确定度和复位例外。不能因为发射间隔为 8，就把逐拍流水路径整体设置为 8 拍 multicycle。

不对正常数据路径随意设置 false path。RAM 副本布置应靠近对应 matcher；广播写路径和复位释放扇出需在实现中评估。

## 16. 需求追踪与版本边界

### 16.1 需求追踪

| 需求 | 规格位置 | 验证入口 |
| :--- | :--- | :--- |
| 12-bit、3×4-bit、16 分支 Trie | 2、7 | F02、F07～F10 |
| 4096 槽位、Flow ID 透明传递 | 2、6、9 | F02～F04、F17 |
| 稳定重复排序、RC/TT 一致 | 7.6、8、9.3 | F03～F06、F19 |
| 显式 epoch、跨回绕排序 | 3、7.5、9.5 | F13～F16、F21 |
| O(1) 出队、1 拍生产响应 | 4.4、9.4、10.3 | F01、F11、F12、F20 |
| 固定插入时延 | 10.2 | F07～F10、时延断言 |
| 多事务重叠及 RAW 安全 | 10.4、11 | F11、F18、F22 |
| 同步 RAM、可实现端口预算 | 6、10.5、15 | RAM 单元测试、综合 |
| 满/空、背压、复位 | 4、12、13 | F17、F20、F23 |
| 目标频点及实际吞吐 | 10.6、15.2 | 周期计数、STA |

### 16.2 已冻结的 V1 选择

- 跨回绕采用显式 16-bit epoch、最多相邻两代共存；每代保持原 12-bit Trie。
- 一条全局单向链表，两个连续 epoch 区段；物理地址池共享。
- 精确 RC 删除，不采用按窗口推进批量隔离旧子树的清理方式。
- 固定 8 拍共享发射间隔，Insert 7 拍提交、Extract 1 拍提交。
- 插入末尾写回和后一事务重叠，通过完整逻辑 overlay 及同步旁路保证一致性。
- 输出使用两项响应 FIFO，独立请求握手与响应握手。

### 16.3 后续变更必须重新评审的事项

支持三代以上 epoch、改变 tag 位宽/Trie 级数、把发射间隔降至 4/1 拍、同拍接受插入和出队、引入任意位置删除、增加独立 F_min 查询、增加 packet ID、使用更高 RAM read latency，均需要更新接口或端口/一致性/时延证明。

当前没有阻碍启动 RTL 的未定义功能分支。尚待实现阶段提供的证据是：目标工艺/FPGA 型号与 RAM 宏选型、综合资源、实际 Fmax、RTL 回归和 STA 结果；这些证据不应被当作已经取得的性能保证。

## 附录 A. 事务级行为伪代码

本伪代码描述逻辑行为，不表示可以将整个操作综合成单拍组合逻辑。物理访问必须按第 10 节流水执行。

~~~text
INSERT(epoch, tag, flow):
    require admission granted
    n = reserve_free_slot()
    bank = epoch[0]
    pred_key = trie_predecessor(bank, tag)    // <=，包含相同键
    if pred_key.valid:
        p = TT[bank, pred_key.tag].tail_ptr
    else if epoch is next_epoch and old bank is nonempty:
        p = bank_tail[old]
    else:
        p = NULL

    s = logical_NEXT[p] if p.valid else head
    delta = {
        DATA[n] = {epoch, tag, flow},
        NEXT[n] = s,
        NEXT[p] = n if p.valid,
        head/tail/bank/cache updates,
        RC[bank,tag] += 1,
        TT[bank,tag] = {valid=1, tail_ptr=n},
        set path if old RC == 0,
        queue_level += 1,
        alloc_reserved -= 1
    }
    publish_all(delta) at E7
    retire at E9

EXTRACT():
    require admission granted and response slot reserved
    h = head_cache
    successor_record = logical_read_node(h.next) if h.next.valid
    delta = {
        head/cache = successor_record or NULL,
        bank/global state and optional base advance,
        RC[h.bank,h.tag] -= 1,
        clear TT and exact path if old RC == 1,
        FREE[free_count] = h.ptr,
        free_count += 1,
        queue_level -= 1,
        response_fifo.push(h.payload)
    }
    publish_all(delta) at E1
    retire at E2
~~~

## 附录 B. 阅读实现代码时应首先排查的错误

1. 把 RC 或 queue_level 定义成 12 bit，导致满容量回绕。
2. TT 指向重复组头而非尾，破坏 FCFS。
3. 删除同值组第一项时就清 marker，或删除最后一项后保留 TT。
4. 仅在当前叶寻找前驱，未覆盖更高层备用分支。
5. 对回绕后的 tag 直接无符号比较，把新代 0 放到旧代 4095 前。
6. TT/RC 地址遗漏 bank，或 bank 重用时留下旧代有效项。
7. 把指针 0/4095 保留作 NULL，使容量实际少一个槽位。
8. 更新 RAM 的 NEXT[p]，但忘记同步修补 head_cache.next。
9. 将 extract_val 实现成无背压的单拍脉冲，或响应消费时重复释放节点。
10. 在 NEXT 两次写入之间让后继事务读到部分更新的链表。
11. overlay 退休过早，造成上一拍同址读返回旧值。
12. 宣称插入“固定 7 拍”却在已接受后因依赖、端口或 FIFO 再停顿。

## 附录 C. 本次规格审阅记录

以下检查于 2026-09-11 在独立的临时 Python 模型中完成，验证对象是本文的逻辑规则和周期表；未生成或验证 RTL：

| 检查 | 结果 |
| :--- | :--- |
| 本地 Markdown 引用 | 7 个文件链接均可解析 |
| 容量/存储算式 | 4096 满容量需要 13-bit 计数；RAM 位数合计 492,576 bit |
| 4×4 分组 matcher 公式 | 65536 个 bitmap × 16 个 query × LE/LT，共 2,097,152 组通过 |
| 三类 Trie 前驱候选 | 71 个空/稀疏/稠密集合，每集合遍历全部 4096 个 query，共 290,816 次与排序集合结果一致 |
| 相邻事务端口排程 | Insert/Insert、Insert/Extract、Extract/Insert、Extract/Extract 在 8 拍间隔下，每物理副本均不超过 1R1W |
| 链表/TT/RC/头缓存规则 | 64 槽位模型执行 20,000 次混合操作，与独立稳定排序列表逐次比较通过，含重复键、新最小值、两代交错和 epoch 65535→0 |

这些检查不涵盖 RTL 采样沿、实际 RAM 宏行为、fault 注入或门级时序。第 14 节规定的完整 RTL 回归与第 15 节 STA 仍须在实现阶段执行。
