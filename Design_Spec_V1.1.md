# wfq_tag_sort_engine — Design Specification V1.1

| 项目 | 内容 |
| :--- | :--- |
| 文档版本 | V1.1 |
| 日期 | 2026-09-15 |
| 设计对象 | `wfq_tag_sort_engine` |
| 用途 | 功能 RTL、集成、验证及综合/STA 的完整设计基线 |
| 前一版本 | [Design_Spec_V1.md](Design_Spec_V1.md)，保留作为历史版本 |
| 本版本核心决定 | L1/L2 单份寄存器组合读；L3 单份单端口同步 SRAM；默认 II=5，支持编译期 II=6 |
| 状态 | 规格及 Python 周期模型检查完成；尚无 RTL、RAM 宏仿真、综合或 STA 结果 |

本文取代 V1.0 作为后续实现基线。“必须”表示验收要求，“建议”表示在保持行为和时序契约前提下可选择的实现方式。两种发射配置均在本文完整定义，不依赖实现者自行补齐冲突处理。

## 1. 目标、范围与版本变化

### 1.1 功能目标

接收 `{epoch, finishing_tag, flow_id}`，在片内维护稳定有序队列，按请求移除并返回最小项：

1. 同代按 12-bit 无符号 tag 升序；相邻两代共存时旧代整体排在新代之前。
2. 相同 `{epoch,tag}` 按插入握手顺序 FCFS；Flow ID 不作为第二排序键。
3. 默认共享 4096 个物理槽位、512 个 Flow ID，重复键分别占用槽位。
4. 使用三级 Multi-bit Trie、TT、RC、单向有序链表、空闲地址栈及头缓存。
5. L1/L2 组合读、不复制状态；L3 单端口同步读写，读延迟 1 拍。
6. 接受后的提交时延固定，无数据相关回放、重试或内部停顿。
7. 默认每 5 拍接受一个操作；6 拍配置用于增加上层搜索的流水分割。
8. 前一事务写回与后一事务查找/出队可以重叠，后者必须看到完整的已提交逻辑状态。

### 1.2 系统边界

上游完成 WFQ 虚拟时间、权重、包长及 finishing tag 的计算、量化和 epoch 编码。本模块不实现这些计算，也不实现 WF²Q eligibility 判断。

不包含 Shared Packet Buffer、Packet Buffer Write/Read Control，不保存包内容或包缓冲指针。输出 Flow ID 由外部映射到待服务数据包；若外部使用逐流 FIFO，同流的逻辑 finishing tag 必须按该 FIFO 的包顺序非递减。本模块不检查该集成约束。

独立 peek/F_min 连续反馈、任意位置删除、同拍插入加出队、packet ID 扩展均不属于本版本。`min_tag_out` 是响应 FIFO 中已出队项的数据，不能当作当前驻留最小值。

功能 RTL 同时面向 ASIC/FPGA。ECC、MBIST、scan 和 repair 控制由技术相关 wrapper/SoC 集成层负责，本功能接口不新增 BIST 端口。测试模式不得与正常请求并行；返回正常模式必须复位初始化，并保持本文正常模式下的端口和延迟契约。实际 ASIC wrapper 定型前需要落实该集成责任。

### 1.3 参考资料及权威顺序

| 编号 | 本地文件 | 用途 |
| :--- | :--- | :--- |
| R0 | [Initial_Design_Spec.md](Initial_Design_Spec.md) | 初始目标和范围 |
| V1.0 | [Design_Spec_V1.md](Design_Spec_V1.md) | 前版功能语义和历史决策 |
| R1 | [A Scalable Packet Sorting Circuit](Paper_in_Markdown/A_Scalable_Packet_Sorting_Circuit.md) | III-A～III-D：Trie、备用路径、TT、链表 |
| R2 | [Fully Hardware Based WFQ Architecture](Paper_in_Markdown/Fully%20hardware%20based%20WFQ%20architecture.md) | 系统边界和重复标签 FCFS |
| R3 | [Design and Analysis of Matching Circuit](Paper_in_Markdown/Design_and_Analysis_of_Matching_Circuit.md) | Select & Look-Ahead |
| N1 | [tag_refcount_array](Paper_in_Markdown/Important_Notes/tag_refcount_array.md) | 最后同键项删除和陈旧指针风险 |
| N2 | [finishing_tag_range_wraparound](Paper_in_Markdown/Important_Notes/finishing_tag_range_wraparound.md) | 回绕排序问题 |
| A1 | [RAM_Replica_Analysis_0915.md](RAM_Replica_Analysis_0915.md) | 单副本、精确路径早读、唯一备用叶 |
| A2 | [Spec_Review_Analysis_0911.md](Spec_Review_Analysis_0911.md) | 参数公式、响应沿语义、注错及验证修正 |

本文优先于 V1.0 和分析文件。A1 中的上层同步读及 II=8 排程是中间方案，不是本文当前约束。论文转录存在缺失的图表，论文报告的频率不能作为本设计的 STA 结果。

### 1.4 相对 V1.0 的实质变化

| 事项 | V1.0 | V1.1 |
| :--- | :--- | :--- |
| L1/L2 读取 | 同步 1 拍 | 单份寄存器组合读，0 拍 |
| L2/L3 副本 | L2×2、L3×3 | 每层一份状态，epoch bank 为不同数据分区 |
| L3 端口 | 3R1W 的副本组织 | 真正 1RW，每拍读或写一次 |
| 前驱查找 | 同拍展开 A/B/C 叶 | 精确叶早读，再读取唯一备用叶 |
| 聚合发射间隔 I | 8 | 默认 5；可选 6 |
| 插入提交 C | E7 | E_(I-1)：默认 E4，可选 E5 |
| 插入最后写/退休 | E8/E9 | E_I/E_(I+1) |
| 出队提交/退休 | E1/E2 | E1/E2，保持 |
| 提交描述符形成 | 独立完整寄存阶段后提交 | 提前锁存主体，NEXT 返回周期补齐末级字段并提交 |
| 上层路径分割 | RAM 级间寄存 | FAST5 组合 max_b 前视；PIPE6 寄存 aC 再读 L2 |
| 状态位估计 | 492,576 bit | 475,680 bit，含上层 544 bit 寄存器，不含流水和组合逻辑 |

缩短间隔不只是改常数：本版本同时改变查找、提交末级和写回排程，并重新给出端口及指针释放证明。FAST5 增加组合前视逻辑，PIPE6 多保留一级候选寄存；两者均不增加完整存储副本。

## 2. 参数、派生常量与类型

### 2.1 配置参数

| 名称 | 默认值 | 约束 |
| :--- | ---: | :--- |
| `TAG_WIDTH` | 12 | 固定 |
| `LITERAL_WIDTH` | 4 | 固定 |
| `LEVELS` | 3 | `TAG_WIDTH/LITERAL_WIDTH` |
| `BRANCHING_FACTOR` | 16 | `2**LITERAL_WIDTH` |
| `EPOCH_WIDTH` | 16 | 固定 |
| `EPOCH_BANKS` | 2 | 固定 |
| `PTR_WIDTH` | 12 | 4～16 |
| `MEM_DEPTH` | 4096 | 必须等于 `2**PTR_WIDTH` |
| `FLOW_ID_WIDTH` | 9 | 8～12 |
| `COUNT_WIDTH` | 13 | `$clog2(MEM_DEPTH+1)` |
| `ISSUE_INTERVAL` | 5 | **仅允许 5 或 6，编译期配置，运行中不可切换** |
| `RSP_DEPTH` | 2 | 两项寄存器响应 FIFO |
| `MAX_INFLIGHT` | 2 | 执行和未退休写回事务总数上限，不含已退休响应 |

`MEM_DEPTH` 是全部 bank/Flow ID 共享容量。不能把 tag 值域、每 bank metadata 深度和物理槽位数混为同一参数。

### 2.2 唯一派生的周期常量

定义 I=ISSUE_INTERVAL，以下必须使用 localparam 派生，不允许分别覆盖：

| 常量 | 公式 | FAST5 | PIPE6 |
| :--- | :--- | ---: | ---: |
| `FALLBACK_READ_EDGE`，B | I-4 | 1 | 2 |
| `TT_READ_EDGE`，T | I-3 | 2 | 3 |
| `NEXT_READ_EDGE`，P | I-2 | 3 | 4 |
| `INSERT_COMMIT_LATENCY`，C | I-1 | 4 | 5 |
| `INSERT_PATCH_EDGE` | I | 5 | 6 |
| `INSERT_RETIRE_LATENCY`，R | I+1 | 6 | 7 |
| `EXTRACT_COMMIT_LATENCY` | 1 | 1 | 1 |
| `EXTRACT_RETIRE_LATENCY` | 2 | 2 | 2 |

FAST5/PIPE6 只是 I=5/6 的名称，不另设可产生矛盾组合的独立 mode 参数。任何非法参数组合须在 elaboration 时失败。

### 2.3 数据类型、地址和位序

~~~systemverilog
typedef logic [TAG_WIDTH-1:0]     tag_t;
typedef logic [EPOCH_WIDTH-1:0]   epoch_t;
typedef logic [PTR_WIDTH-1:0]     ptr_t;
typedef logic [FLOW_ID_WIDTH-1:0] flow_id_t;
typedef logic [COUNT_WIDTH-1:0]   count_t;
typedef struct packed { logic valid; ptr_t ptr; } link_t;
typedef struct packed {
    epoch_t epoch;
    tag_t tag;
    flow_id_t flow_id;
} payload_t;
~~~

NULL 为 link.valid=0，ptr 此时不参与寻址；物理地址 0 和最大地址均可使用。计数必须能表示 0～MEM_DEPTH，默认 4096 需要 13 bit。

~~~text
tag = {a,b,c}
a = tag[11:8]; b = tag[7:4]; c = tag[3:0]
bank = epoch[0]
L1 索引 = bank
L2 索引 = {bank,a}
L3 地址 = {bank,a,b}
TT / RC 地址 = {bank,tag}
~~~

位图 bit i 对应 literal i，bit 15 为最大值。输入 tag 和所有 literal 比较使用无符号语义。

## 3. 排序和 epoch 协议

### 3.1 稳定排序

排序键为 `(epoch 的逻辑先后, tag, insert_fire 的先后)`。相同键通过 TT 指向同值尾实现 FCFS，无需在 RTL 节点中保存序号。

每次出队取其之前已接受操作形成的当前队列最小项；之后允许插入更小 tag，因此不对整个历史输出序列要求单调。Flow ID 仅随数据传递。

### 3.2 epoch 生成和窗口

上游为每条描述符提供完整 epoch，tag 回绕进入下一代时 epoch 加 1，按 16 bit 截断。不同流导致相邻输入 tag 下降不代表回绕。

维护 base_epoch 为当前最旧非空代。非空时只接受 base_epoch 或 `base_epoch+1`；两者按最低位进入不同 bank，每 bank 保存完整 bank_epoch：

1. 允许相邻两代交错到达，旧代所有节点先于新代。
2. 旧代清空而新代非空时，在该次出队提交沿推进 base_epoch。
3. 清空 bank 的 RC、TT valid 和 Trie marker 已经精确归零，可供再下一代使用，无额外清表延迟。
4. 第三代请求背压；它不能阻止合法出队推进窗口。
5. 完全为空且可发射时，第一条插入可以任意 epoch 重建 base。
6. 空队列时 base_epoch 可保留旧寄存值，但没有排序/准入语义，不能拒绝首条任意 epoch。
7. 未消费响应保存完整 epoch，不阻止槽位或 bank 重用。

过去代或超窗输入不被接受，insert_epoch_blocked=1。上游负责避免将失效历史描述符当作空队列后的新窗口输入。

### 3.3 示例

| 驻留/插入 | 必须行为 |
| :--- | :--- |
| 旧代 4090、4095，新代 0、10 | 旧 4090 → 旧 4095 → 新 0 → 新 10 |
| epoch 65535/tag 4095 与 epoch 0/tag 0 | epoch 65535 先出队，不直接按拼接无符号数比较 |
| 相邻两代相同 tag | 两个不同键，RC/TT 位于不同 bank |
| 当前有 epoch 9、10，输入 11 | 不接受，直到 9 排空并推进窗口 |

## 4. 顶层接口与流量控制

### 4.1 接口

~~~systemverilog
module wfq_tag_sort_engine #(
    parameter int TAG_WIDTH       = 12,
    parameter int LITERAL_WIDTH   = 4,
    parameter int EPOCH_WIDTH     = 16,
    parameter int PTR_WIDTH       = 12,
    parameter int MEM_DEPTH       = (1 << PTR_WIDTH),
    parameter int FLOW_ID_WIDTH   = 9,
    parameter int ISSUE_INTERVAL  = 5,
    parameter int COUNT_WIDTH     = $clog2(MEM_DEPTH + 1)
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

派生参数即使可见，也禁止不一致覆盖。本版本增加 ISSUE_INTERVAL 配置，提交周期相对 V1.0 有明确变化，集成方必须按该配置检查提交脉冲。

### 4.2 握手、准入和仲裁

~~~text
insert_fire  = insert_val && insert_ready
extract_fire = extract_req && extract_ready
rsp_fire     = extract_val && extract_out_ready
~~~

在 clk 上升沿握手；被背压时源保持 valid 和 payload，extract_req 持续为 1 表示持续请求、每次握手独立出队。源不得等待 ready 才拉高 valid。

每次接受一个操作后，在随后 I-1 个沿禁止新接受，第 I 个沿起可接受；没有合格请求时保持可发射状态，不强制等待下一个整倍数槽。

插入候选须满足 init_done、无 fault、可发射、free_count>0、epoch 合法。出队候选须满足 init_done、无 fault、可发射、queue_level>0、有响应预留信用。

两类同时合格时 round-robin；复位后首次冲突优先出队，每次接受后将下次冲突优先权给另一类。每沿只允许一个 fire。不合格请求不能阻塞另一类。

ready 组合依赖 valid、资源和仲裁是有意选择。集成方按目标互联协议及组合路径要求设置寄存隔离；不是所有连接都无条件需要 skid buffer。

满队列不能预支同拍出队的地址，先出队、后续发射再插入；空队列同时请求时只接受插入。不存在隐式同拍换入换出。

### 4.3 固定响应生产与可背压消费

每个 extract_fire 当拍预留一个响应槽，E1 提交并将完整 payload 放入 FIFO，extract_commit 在 E1 沿后保持一拍。

若 FIFO 原为空，新响应在 **E1 沿后**使 extract_val 和 payload 有效；下游一直 ready 时最早 **E2 沿**消费。若有更早响应，按 FIFO 顺序等待，不能保证新 payload 在 E2 成为队头。

extract_val 为 FIFO valid，不是脉冲。valid 且 !extract_out_ready 时所有输出数据和 valid 保持不变。响应消费仅释放 FIFO，不再次删除节点或释放物理地址。

两项 FIFO，保守信用条件 `rsp_count+rsp_reserved<2`，不预支当拍可能消费的位置。允许同拍已有响应被消费和新响应入队；先依据沿前信用决定接受。

### 4.4 状态输出

| 信号 | 定义 |
| :--- | :--- |
| queue_level | 已提交且未出队提交的节点数，不含待提交插入和响应 |
| empty | init_done 时等于 `queue_level==0` |
| full | init_done 时等于 `free_count==0`，包含已预留插入槽 |
| insert_commit | 每个插入在 E_C 沿后产生一拍脉冲 |
| extract_commit | 每个出队在 E1 沿后产生一拍脉冲，与响应入队同时 |
| busy | 有接受后尚未退休的事务，包括旧写回 |
| idle | `init_done && !fault && !busy && rsp_count==0 && rsp_reserved==0` |
| insert_epoch_blocked | `init_done && insert_val && !epoch_legal` |
| fault/fault_code | 首个内部一致性故障的粘滞状态及编码 |

idle 不要求数据队列为空，也不表示发射冷却已经结束。empty 判断已提交队列，full 判断实际可分配容量，两者采用不同口径是设计意图；二者均不能替代 ready。

如果接受前为空，待提交插入期间 empty 保持 1；原来非空则保持 0。对已提交 queue_level 做组合空比较是合法实现。

## 5. 微架构与状态所有权

### 5.1 数据通路

~~~mermaid
flowchart LR
    I["Insert / Extract"] --> A["Admission + RR + credit"]
    A --> P["Transaction pipeline: FAST5 / PIPE6"]
    P --> U["L1/L2: one register copy, combinational read"]
    U --> L["L3: one SRAM copy, one R/W per edge"]
    L --> TT["TT: same-key tail"]
    P --> RC["Reference counts"]
    TT --> N["DATA / NEXT sorted list"]
    P --> F["Free address stack"]
    F --> N
    N --> H["Head cache"]
    H --> Q["Reserved response FIFO"]
    P --> C["Atomic commit + pending write forwarding"]
    C --> U
    C --> L
    C --> TT
    C --> RC
    C --> N
~~~

### 5.2 建议模块划分

| 模块 | 职责 |
| :--- | :--- |
| wfq_tag_sort_engine | 接口、参数、模块连接 |
| wfq_admission_ctrl | I 拍间隔、RR、容量/响应信用 |
| wfq_epoch_ctrl | base/next 和 bank 生命周期 |
| wfq_trie_upper_regs | L1/L2 状态、组合读、FAST5 max_b 前视或 PIPE6 读选择 |
| wfq_trie_search | 精确叶、唯一备用叶、阶段 valid 与最终前驱 |
| wfq_matcher16 | 分组 Select & Look-Ahead LE/LT/MAX |
| wfq_translation_table / wfq_tag_refcount_array | TT/RC 访问与更新 |
| wfq_list_manager | 链接、head/tail/cache 及 bank 区段 |
| wfq_free_slot_stack | 分配与释放 |
| wfq_commit_ctrl | 提前形成描述符主体、末级补齐、提交与退休 |
| wfq_sync_ram_1rw | L3 单端口同步包装 |
| wfq_sync_ram_1r1w | 其余同步表/节点存储及读写旁路 |
| wfq_response_fifo / wfq_init_ctrl | 响应和初始化 |

允许合并模块，不允许因此改变端口、周期或状态更新所有权。

### 5.3 必备状态

全局至少包含 queue_level、free_count、alloc_reserved、head、tail、head_cache、base_epoch、发射冷却计数、RR、两个事务/写回上下文和响应状态。

每 bank 至少包含 valid、完整 bank_epoch、bank_count、bank_head、bank_tail、bank_min_tag、bank_max_tag。每代构成链表中连续区段，旧代尾接新代头。

head_cache 保存 `{head.ptr,payload,next}`，每次提交同步更新；只缓存 payload 而遗漏 next 不满足单拍出队要求。

每次插入保存独立的 old_root、old_parent_exact、old_leaf_exact、old_rc 和候选信息。L2 的备用读取不能覆盖维护精确路径所需的快照。

## 6. 存储、组合读取与端口契约

### 6.1 资源表

深度包含两个 epoch bank，副本数为同一节点状态的镜像数量：

| 资源 | 默认深度×宽度 | 状态副本 | 读取延迟 | 写入及访问能力 |
| :--- | :--- | ---: | ---: | :--- |
| L1 | 2×16 | 1 | 0 | 32 bit 寄存器；每拍最多一项同步写 |
| L2 | 32×16 | 1 | 0 | 512 bit 寄存器；组合选择/前视；每拍最多一项同步写 |
| L3 | 512×16 | 1 | 1 | **1RW，同拍最多读或写一次** |
| TT | 8192×13 | 1 | 1 | 1R1W；valid+tail_ptr |
| RC | 8192×13 | 1 | 1 | 1R1W；0～4096 |
| DATA | 4096×37 | 1 | 1 | 1R1W；epoch+tag+flow_id |
| NEXT | 4096×13 | 1 | 1 | 1R1W；next_valid+next_ptr |
| FREE | 4096×12 | 1 | 1 | 1R1W；空闲地址栈 |

L2 的组合多读或前视是从一份寄存器状态扇出，不复制状态。不将 L1/L2 的输出强制再封装成 1 拍读接口，也不取消显式候选寄存器。

### 6.2 参数公式和状态位估算

~~~text
L(level) 深度 = EPOCH_BANKS * BRANCHING_FACTOR**(level-1)
L(level) 位宽 = BRANCHING_FACTOR
TT_WIDTH = NEXT_WIDTH = 1 + PTR_WIDTH
RC_WIDTH = COUNT_WIDTH = clog2(MEM_DEPTH+1)
DATA_WIDTH = EPOCH_WIDTH + TAG_WIDTH + FLOW_ID_WIDTH
FREE_WIDTH = PTR_WIDTH
TT_DEPTH = RC_DEPTH = EPOCH_BANKS * 2**TAG_WIDTH
DATA_DEPTH = NEXT_DEPTH = FREE_DEPTH = MEM_DEPTH

L1/L2 状态寄存器 = 32 + 512 = 544 bit
L3 SRAM            = 8192 bit
TT / RC            = 各 106496 bit
DATA                = 151552 bit
NEXT                = 53248 bit
FREE                = 49152 bit
同步存储数据位合计   = 475136 bit = 58.00 KiB
加 L1/L2 状态后合计  = 475680 bit ≈ 58.07 KiB
~~~

相对 V1.0 减少 16,896 bit，即 2112 字节的镜像状态。不包含事务/快照/输出寄存器、组合前视逻辑、ECC、宏粒度填充、BRAM 浪费及物理实现缓冲，不能等同于最终面积减少量。

R1 单棵 Trie 的上两层为 16+256=272 bit、底层为 4096 bit。本设计为跨回绕共存保存两代不同状态，因此分别为 544 bit 寄存器和 8192 bit SRAM；这个翻倍来自 epoch 功能分区，不是读取副本。

### 6.3 0 拍寄存器读取

组合读在地址和状态稳定后经 mux/布线延迟输出，不等待时钟，不表示传播时间为 0。地址来自已接受事务的寄存输入，不把复杂搜索未经约束地前移到 E0 之前。

L1/L2 在提交沿同步写，沿前读旧值、沿后读新值。下一事务最早在提交后一沿接受，因此没有“同沿新事务必须读到尚未寄存的新状态”的正常需求。

提交使用事务快照和已准备结果，不使用更新后的组合输出反馈重算本次提交。组合毛刺不能直接触发异步写、提交或 FIFO 操作。

### 6.4 同步 RAM 与转发

在 E_k 采样读地址，q 在随后周期稳定，下一级在 E_(k+1) 使用。读 q 后增加输出寄存器会增加契约延迟，禁止隐式加拍。

L3 每拍必须满足 `read_en + write_en <= 1`，不能以 1R1W 宏的额外端口规避排程。可合为 512×16 宏或两个不同 epoch 的 256×16 分区，但全局按一个访问端口预算。

其他存储每拍最多一读一写。每个同步读请求携带事务归属、label/read_valid 以及必要的 bypass 数据，优先级为：

~~~text
本沿新逻辑提交的值 > 最新的尚未退休已提交值 > 原 RAM q
~~~

同沿实际写总线需与此逻辑顺序一致；NEXT 延迟修补属于较早已提交事务的 pending overlay，不是新提交。清零、TT invalid、NEXT NULL 都必须能转发。

L3 不允许同沿读写，但 NEXT 必须支持，特别是旧事务 E_I 写 NEXT[p] 与新出队 E0 读取下一头 NEXT 的同址情况。读请求沿捕获旁路信息，不能在旧事务退休时丢失。

### 6.5 空闲地址栈

初始化 FREE[i]=i、free_count=MEM_DEPTH。插入接受时读旧 `FREE[free_count-1]`，free_count--、alloc_reserved++，E1 捕获 n 并独占。

插入提交时 alloc_reserved--、queue_level++。出队提交时写 `FREE[旧 free_count]=旧 head.ptr`，free_count++、queue_level--。响应已保存完整 payload，释放地址不等待响应消费。

正常运行区间每沿更新后满足：

~~~text
free_count + alloc_reserved + queue_level == MEM_DEPTH
~~~

栈地址算术先使用 COUNT_WIDTH 检查，合法后再截取 PTR_WIDTH；free_count=0 时不能减一寻址。DATA/NEXT 释放后可保留旧比特，但无有效引用允许访问它们。

## 7. Trie、Matcher 与唯一备用路径

### 7.1 精确不变量

在每个逻辑提交后的视图中，对任意 bank、a、b、c：

~~~text
L3[bank,a,b][c] == (RC[bank,{a,b,c}] != 0)
L2[bank,a][b]   == OR(L3[bank,a,b])
L1[bank][a]     == OR(L2[bank,a])
~~~

Trie 只表示键是否存在，不存节点数量。L1/L2 寄存器是权威状态，不能另建一个延迟更新、可能陈旧的“快速副本”供搜索。

### 7.2 Matcher 契约

`wfq_matcher16` 为组合逻辑。输入 bitmap[15:0]、query[3:0]、mode；输出 found、index[3:0]、onehot[15:0]、exact。

| 模式 | 返回最大索引 i 的条件 |
| :--- | :--- |
| LE | bitmap[i]=1 且 i<=query |
| LT | bitmap[i]=1 且 i<query |
| MAX | bitmap[i]=1 |

无解时 found=0、index=0、onehot=0、exact=0。index=0 必须与 found 配合；它也是合法命中。exact 仅在 LE 且选中 query 时为 1。

LE/LT 掩码应显式生成 16 个候选 bit，避免 query=0 下溢、query=15 时左移 16 位和有符号常数扩展。MAX 不需要 query。

采用 R3 的 Select & Look-Ahead 分组预计算思想：4 组×4 bit，组内最大位与各组非空并行求值，再选择最高非空组。

~~~text
C[i] = 满足模式条件的 bitmap[i]
G[g] = OR(C[4*g +: 4])
S[g] = G[g] AND NOT(OR(G[3:g+1]))
local[g][j] = C[4*g+j] AND NOT(OR(C[4*g+3:4*g+j+1]))
onehot[4*g+j] = S[g] AND local[g][j]
~~~

空范围 OR 为 0。上述为数学伪代码，不是可直接编译的动态 part-select。RTL 显式表达分组并行逻辑，避免跨整个字的串联逐位优先链；速度以综合后的实际结构为准。

### 7.3 A/B/C 候选及唯一备用叶

只在输入所属 epoch 内求 `P_same=max{y | y<=x 且 RC[bank,y]>0}`，x={a,b,c}：

| 类别 | 范围 | 求值方式 |
| :--- | :--- | :--- |
| A | 高 8 bit 等于 {a,b} | cA=LE(L3[a,b],c) |
| B | 高 4 bit 等于 a，中间 4 bit 小于 b | bB=LT(L2[a],b)，cB=MAX(L3[a,bB]) |
| C | 高 4 bit 小于 a | aC=LT(L1,a)，bC=MAX(L2[aC])，cC=MAX(L3[aC,bC]) |

三类互斥且覆盖所有 y<=x，严格优先级 A>B>C。E0 直接读地址已知的精确叶 L3[bank,a,b]，并保存其旧值供更新使用：

1. A 命中：采用 A，备用 L3 read_en=0。
2. A 未命中而 bB 有效：只读 B 叶。L2 的精确 marker 保证此叶非空，B 必然优于全部 C。
3. A 未命中、bB 无效而 aC 有效：只读 C 叶。根/父 marker 保证该父及叶非空。
4. 上述均无效：无同代前驱，不读备用叶。

因此一次插入最多读取 L3 两次：精确叶一次、唯一备用叶一次。不能在 B 叶返回空时再试 C：这属于 marker 一致性故障，正常路径不应发生，必须 fail-stop 而非延长事务。

所有候选须检查 found 和相应 marker。屏蔽无效 read_en，禁止将无效候选的默认地址 0 当成有效结果。

### 7.4 FAST5：组合前视与 0 拍读取

E0 接受后至 E1 之前，并行执行：

- 对 L1[bank] 做 LT(a)，产生 aC。
- 组合选择 L2[bank,a] 并做 LT(b)，产生 bB。
- 对每个 L2 寄存器字独立计算 `max_b[bank,a_index]=MAX(L2[bank,a_index])`；aC 出来后选择对应的 max_b 结果作为 bC。
- 对 E0 所读精确 L3 的 q 做 LE(c)，产生 A；按 A/B/C 优先级驱动 E1 的唯一备用叶读地址。

两 bank 共 32 个 16-bit 字的 MAX 结果均为**组合导线**，不得写成另一个按拍维护的存储表。综合可以共享等价逻辑，但须保留预计算目的；这增加编码器、选择器和布线，不增加 L2 状态副本。

C 路径的结构是“根 LT 与各父 MAX 并行，再选择编码结果”，避免把“根 LT → 选择完整 L2 字 → 再运行 MAX”全部串联。仍然存在编码、mux、A 命中选择及 SRAM 地址建立时间，不能宣称 0 延迟电路。

E1 同时保存 old_root、old_parent_exact、old_leaf_exact、old_RC、分配地址及候选控制。上层虽可组合读取，事务后续更新仍使用本次快照，不能混用其他阶段地址。

### 7.5 PIPE6：增加上层流水分割

E0～E1 计算 A、bB、aC，E1 寄存候选和精确路径快照。E1～E2 使用已寄存 aC 组合读 L2[bank,aC] 并计算 MAX，E2 才发唯一备用 L3 读。

因此 PIPE6 可以只为所选 L2 字实现 C 的 MAX 通路，不要求 FAST5 的全字组前视网络；L2 仍是一份 512-bit 寄存器。TT、NEXT、提交和写回随备用读统一后移一拍。

无备用、空 bank、重复标签等情况也等待对应配置的固定提交沿，不采用数据相关提前完成。

### 7.6 同代与全局前驱

若同代前驱有效，读取 TT[bank,pred_same_tag]，其同值尾地址为 p；否则：

- 插入属于下一代且旧代非空：p=旧代 bank_tail。
- 其他情况：p=NULL，新节点成为全局 head。

跨代尾来自 bank 状态寄存器，无需读旧代 Trie。即使不需要 TT/NEXT，也通过阶段 valid 屏蔽访问并保持固定排程。

整体 `trie_exact` 定义为“同代查找最终命中且完整 pred_same_tag==input_tag”，必须等于 `old_RC!=0`。不能把根或父 matcher 的局部 exact 当成完整键存在。

### 7.7 精确置位与清除

插入旧 RC=0 时，使用精确路径快照：

~~~text
new_leaf   = old_leaf   | onehot(c)
new_parent = old_parent | onehot(b)
new_root   = old_root   | onehot(a)
~~~

插入旧 RC>0 时 Trie 保持。出队旧 RC=1 时：

~~~text
leaf_empty_after   = (old_leaf   == onehot(c))
parent_empty_after = leaf_empty_after AND (old_parent == onehot(b))
new_leaf   = old_leaf & ~onehot(c)
new_parent = leaf_empty_after   ? old_parent & ~onehot(b) : old_parent
new_root   = parent_empty_after ? old_root   & ~onehot(a) : old_root
~~~

两个 16-bit 相等比较可以并行实现，减少先清叶再逐级零检测的依赖。以上等价性依赖有效目标 marker 已置位，并须实施第 13 节局部一致性检查。只在必要时写父/根；禁止清除兄弟分支。旧 RC>1 时所有 marker 和 TT 保持。

这份排程由 A1 的精确路径早读和唯一备用叶推导而来；R1 支持上层寄存器、底层单端口 SRAM 的组织，本文不声称上述具体边沿排程就是 R1 的原实现。

## 8. TT 与 RC

### 8.1 Translation Table

TT[bank,tag] 指向该完整键的最后一个 live 节点：

~~~text
TT.valid == (RC != 0)
TT.valid -> DATA[TT.ptr].{epoch,tag} 与 bank_epoch/tag 一致
~~~

每次插入将 TT 更新为 {1,n}；同值新节点接在此前 TT 指向的节点之后，实现 FCFS。最后一项出队时写 {0,0}，非最后出队不修改 TT。

TT 无效时 ptr 不可解引用。不能只按 tag 寻址，也不能把 TT 解释为同值组首节点。

### 8.2 Reference Count

RC 等于该键的 live 节点数，全表 RC 总和等于 queue_level；默认必须能表示 4096。RC 不统计未提交预留和响应。

| 操作 | old_RC | new_RC | TT 动作 | Trie 动作 |
| :--- | :--- | :--- | :--- | :--- |
| 插入 | 0 | 1 | 指向 n、置 valid | 精确路径置位 |
| 插入 | 1～MEM_DEPTH-1 | old+1 | 指向 n | 保持 |
| 出队 | >1 | old-1 | 保持 | 保持 |
| 出队 | 1 | 0 | 清 valid | 精确清叶及必要的父/根 |
| 插入 | MEM_DEPTH | 不提交 | fault | 正常准入不应允许 |
| 出队 | 0 | 不提交 | fault | 表示状态损坏 |

本版本不在同拍合并插入/出队算术；各事务依据上一事务已提交状态分别更新。

## 9. 链表、bank 边界与头缓存

### 9.1 基本不变量

非空队列从 head 沿逻辑 NEXT 恰好访问 queue_level 个互异节点，终点为 tail，tail.next=NULL；空队列 head/tail/cache 均无效。有效节点与 FREE 的有效栈区间、预留地址互斥。

每个非空 bank 是连续区段，旧代段在新代段之前。global head 属于最旧非空 bank，global tail 属于最新非空 bank。head_cache 必须等于逻辑节点 {head.ptr,payload,next}，包含未完成 NEXT 写回的结果。

### 9.2 插入

设 n 为预留地址，p 为第 7 节全局前驱，h 为原 global head：

~~~text
successor = p.valid ? logical_NEXT[p.ptr] : h
DATA[n] = incoming_payload
NEXT[n] = successor
if p.valid: logical_NEXT[p.ptr] = {1,n}
else:      head = {1,n}
if !successor.valid: tail = {1,n}
~~~

本 bank 的更新如下：

| 条件 | 更新 |
| :--- | :--- |
| 原 bank 为空 | 建立 valid/epoch，head=tail=n，min_tag=max_tag=tag |
| tag < 原 min_tag | bank_head=n，min_tag=tag |
| tag >= 原 max_tag | bank_tail=n，max_tag=tag；相同最大键仍追加至尾 |
| 所有插入 | bank_count++，对应 RC/TT 更新 |

原空 bank 的初始化优先于其他比较。非空 bank 的 min/max 更新条件可独立求值。旧代尾后插入新代最小值时，successor 可能是原新代头，不能误改 global tail。

若 n 成为全局头，head_cache 写入新 payload 和 successor；否则 p==head.ptr 时必须将 head_cache.next 修补为 n；其他情况保持缓存。

DATA[n]、NEXT[n] 及元数据在 E_C 物理写入；NEXT[p] 在 E_I 物理写入，但其逻辑结果从 E_C 起由 pending descriptor 提供。没有 p 时屏蔽修补。

### 9.3 重复键

依次插入 {e,10,A}、{e,15,C}、{e,10,B}，结果必须为 10_A→10_B→15_C，TT[e,10]=B，RC[e,10]=2。

删除 A 后 TT 仍指 B；再插入 10_D 接到 B 后。只有最后一个同键实例出队才作废 TT/marker。物理地址和 Flow ID 均不能改变此顺序。

### 9.4 出队

E0 从 head_cache 捕获旧头 h 的完整记录，预留响应；若 h.next 有效，以其地址同时读 DATA 和 NEXT，预取下一头。并行读 h 对应 RC、精确 L3；L1/L2 从寄存器组合取值。

E1 原子执行：

1. 将 h 的完整 payload 写入响应 FIFO。
2. head=h.next，有下一头时用预取结果更新完整 head_cache；队列变空则清 head/tail/cache。
3. 旧头所属 bank_count--；仍非空时更新 bank_head 和 min_tag，bank_tail/max_tag 保持；清空则作废 bank 的 valid/head/tail。
4. 更新 RC，最后同键项同时清 TT 和 Trie。
5. 将 h.ptr 写回 FREE，free_count++、queue_level--。
6. 旧代清空且新代非空时推进 base_epoch；新头直接是新代头。

非空时 global tail 保持。出队不重写 live 节点的 NEXT，也不清已释放 DATA/NEXT。FIFO 保存 payload 后地址可释放。

### 9.5 必须覆盖的边界

| 场景 | 结果 |
| :--- | :--- |
| 唯一节点出队 | 全局及 bank 头尾失效，该键 metadata 归零 |
| 插入新全局最小值后紧接出队 | 使用提交时已更新的 head_cache |
| 在当前头之后插入后紧接出队 | 使用已修补的 head_cache.next |
| 旧代仅一个节点，新代插入最小值 | 旧 head/tail 为前驱，RAM NEXT 和 head_cache.next 同时维护 |
| 旧代最后一项出队 | 直接跨 bank 推进，不重新建链或清表 |
| 响应未消费而地址/bank 重用 | 旧响应完整数据保持，不重新读取 DATA |

## 10. 固定时序、端口与吞吐

### 10.1 边沿定义

E0 为接受沿。表中“读”指 RAM 在该沿采样地址，q 经随后周期组合逻辑在下一沿用于捕获、发起下一读或提交；“写”指在该沿生效。L1/L2 组合读不占额外时钟周期。

逻辑提交在 E_C（插入）或 E1（出队）发生，提交脉冲沿后保持一拍；物理退休在 E_R/E2 释放上下文；响应消费另按 ready/valid。SVA 必须区分沿前采样和 NBA 后寄存输出。

### 10.2 插入逐拍排程

| 动作沿 | FAST5 | PIPE6 | 操作和依赖 |
| :--- | :--- | :--- | :--- |
| 接受 | E0 | E0 | 捕获 payload、预留 n；读 FREE、RC、精确 L3；启动上层组合查找 |
| 上层第一阶段结束 | E1 | E1 | 捕获 n、old_RC 和精确路径快照；得到 A、bB、aC；FAST5 已获得前视 bC |
| 唯一备用 L3 读 E_B | E1 | E2 | 仅在 A 未命中时读 B 或 C；PIPE6 在 E1～E2 完成 C 的 L2 选择和 MAX |
| TT 读 E_T | E2 | E3 | 备用叶 q 经 MAX 确定前驱 tag；同代前驱有效才读 TT；否则选择旧代尾或 NULL |
| NEXT 读 E_P | E3 | E4 | TT q 给出 p，检查 valid；读 NEXT[p]；锁存提交描述符主体 |
| 逻辑提交 E_C | E4 | E5 | NEXT q 给出 successor，补齐末级字段，写 DATA[n]/NEXT[n]/RC/TT/必要 Trie；更新计数、bank、缓存 |
| 前驱修补 E_I | E5 | E6 | 写 NEXT[p]；最早接受下一事务 |
| 退休 E_R | E6 | E7 | 交接已发读的转发信息，释放旧上下文 |

E0 的 FREE/RC/L3 地址直接来自握手 payload、沿前 free_count，无需等待输入寄存器的下一拍输出。接受后其他组合查找只使用已捕获 payload。

**提交末级的实现约束：** E_P 沿前必须准备好与 successor 无关的 RC/TT/Trie 新值、计数增量、bank 更新选择、n/p/payload 和大部分合法性检查；E_P 锁存这些主体字段。E_P～E_C 使用 NEXT q 补齐 NEXT[n]、头缓存 next、global tail 选择及相关局部检查，直接驱动 E_C 的提交写口/寄存器 D，同时锁存 pending descriptor。

不能在 E_C 先锁存完整 descriptor，再到 E_(C+1) 才提交，那会恢复额外一拍并破坏本排程。也不能把 V1.0 的全部计算和检查简单挤入末级：上述预计算是 FAST5 和 PIPE6 的共同要求。

无前驱时 successor 来自已保存 h，重复键不写 Trie，A 命中不读备用叶；所有情况仍在 E_C 提交并在 E_R 退休。

### 10.3 出队逐拍排程

| 上升沿 | 动作 |
| :--- | :--- |
| E0 | 捕获 head_cache、预留响应；读旧头 RC/精确 L3、下一头 DATA/NEXT；组合读 L1/L2 |
| E1 | 检查 RAM q，原子删除旧头、更新下一头缓存/元数据/bank、释放地址并写入响应 FIFO |
| E2 | 退休；FIFO 原空且下游 ready 时可在本沿消费响应 |
| E_I | 最早接受下一事务 |

出队无需遍历 Trie。E0～E1 包含 RAM q、RC 递减、并行位图判空/清位、下一头 epoch 检查及提交建立时间；PIPE6 不会自动放宽该路径。

### 10.4 相邻事务重叠

以 T0 插入、T1 出队为最紧情况：

| 全局沿 | FAST5 | PIPE6 | 动作 |
| :--- | ---: | ---: | :--- |
| T0 接受 | 0 | 0 | 开始插入 |
| T0 提交 | 4 | 5 | 全部逻辑状态可见 |
| T0 最后 NEXT 写 / T1 接受 | 5 | 6 | 允许 NEXT 同拍一写一读；其他 metadata 已完成写入 |
| T0 退休 / T1 提交 | 6 | 7 | 写回上下文必须支持同沿 retire/enqueue |
| T1 退休 | 7 | 8 | 响应仍可等待消费 |
| T2 最早接受 | 10 | 12 | 可安全重分配先前释放地址 |

若 T1 是插入，则在全局 2I-1 提交、2I 修补、2I+1 退休。前一事务已在下一次接受前提交；不允许两个未提交的插入同时在 Trie 中搜索。

### 10.5 端口峰值与碰撞

以下 R/W 都是物理沿，E_C/E_B/E_T/E_P 按配置派生。

| 存储 | 插入 | 出队 | 最紧相邻事务峰值 |
| :--- | :--- | :--- | :--- |
| L1/L2 单份寄存器 | 组合读/预计算；W:E_C | 组合读；W:E1 | 每层每沿至多一个字写；组合多处读取 |
| L3 单份 1RW | R:E0、可选 E_B；W:E_C（首次键） | R:E0；W:E1（最后键） | **一读或一写；无同沿 R+W** |
| RC 1R1W | R:E0；W:E_C | R:E0；W:E1 | 不超过一读一写 |
| TT 1R1W | R:E_T；W:E_C | 最后键 W:E1 | 不超过一读一写 |
| DATA 1R1W | W:E_C | 下一头 R:E0 | 不超过一读一写 |
| NEXT 1R1W | 前驱 R:E_P；新节点 W:E_C；前驱 W:E_I | 下一头 R:E0 | 旧前驱 W 与新出队 R 可同沿同址 |
| FREE 1R1W | R:E0 | W:E1 | 不超过一读一写 |

一次插入的 L3 最晚在 I-1 写，下一事务最早在 I 读；出队 E1 的 L3 写早于下一次 I 的读。epoch 分区不用于放宽此全局单端口约束。

NEXT 同址是合法可达场景：原链 A(tag10)→B(tag20)→C(tag30)，T0 插入 D(tag25)，其前驱 B；T1 紧接出队 A，预取下一头 B 的 NEXT。T0 的 NEXT[B]=D 写回和 T1 的 NEXT[B] 读取同在全局 E_I，返回必须为 D，而非旧 C。仅修补 head_cache 不能覆盖这个场景，RAM 旁路仍是必需的。

### 10.6 吞吐与频率选择

容量、epoch 和响应信用满足，且请求持续合格时：

~~~text
聚合最大接受率                = f_clk / I
均衡插入/出队的每方向操作率    = f_clk / (2*I)
一次插入加一次出队的稳态包服务率 = f_clk / (2*I)
~~~

I=5 相对同频 V1.0 提升 60%；I=6 提升 33.33%。全部为理论排程上限，不包含初始化、空满、超窗、响应背压或输入空隙。

| 时钟 | V1.0 聚合 f/8 | PIPE6 聚合 f/6 | FAST5 聚合 f/5 | PIPE6 均衡包服务 | FAST5 均衡包服务 |
| :--- | ---: | ---: | ---: | ---: | ---: |
| 125 MHz | 15.625 Mops/s | 20.833 Mops/s | 25 Mops/s | 10.417 Mpps | 12.5 Mpps |
| 150 MHz | 18.75 Mops/s | 25 Mops/s | 30 Mops/s | 12.5 Mpps | 15 Mpps |
| 250 MHz | 31.25 Mops/s | 41.667 Mops/s | 50 Mops/s | 20.833 Mpps | 25 Mpps |
| 300 MHz | 37.5 Mops/s | 50 Mops/s | 60 Mops/s | 25 Mpps | 30 Mpps |

ASIC 14/16 nm 的 250～300 MHz、FPGA 的 125～150 MHz 保留为待验证目标。默认选择 FAST5，集成时应对两个配置使用相同工艺、PVT、时序约束和存储宏分别综合/STA，再比较可实现的 `f5/5` 与 `f6/6`：

~~~text
FAST5 实际更快 <=> f5 > (5/6)*f6
~~~

例如 FAST5 达到 250 MHz 与 PIPE6 达到 300 MHz 时均为 50 Mops/s。6 拍增加的是上层流水裕量；若公共出队或提交末级成为瓶颈，它不保证提高频率。

不能把 60 Mops/s 称为 60 Mpps：均衡流量下为 30 Mpps。若每包计 64 byte，300 MHz/FAST5 对应 15.36 Gbit/s 包字节吞吐，PIPE6 为 12.8 Gbit/s；物理线速还需定义帧间隙、前导码及所计包长，本文不据此承诺某一接口线速。

两路持续有效且始终合格时 RR 交替，各每 2I 拍接受一次。离散采样沿上，一路刚错过自身机会而持续合格，最坏再等待 2I-1 个周期，即 FAST5 9 拍、PIPE6 11 拍；因容量/epoch/信用变为不合格的等待不在此界内。

### 10.7 为什么能到 5/6 拍，及进一步压缩的边界

压缩来源分别为：上层组合读；精确叶 E0 早读；最多一个备用叶；FAST5 的组合前视或 PIPE6 的一级分割；提前形成提交主体、NEXT 返回后的直接末级提交。

在 FAST5 的最坏备用路径上，E1 备用 L3 → E2 TT → E3 NEXT → E4 提交构成连续同步依赖。因此本设计选择下一次 E5 接受。若只将 I 改为 4，旧插入 E4 的 L3 写将与新操作 E0 的 L3 读重叠，而且新准入不能依赖沿后才完成的提交状态。

这不是所有 Trie 架构的理论下界；改变存储内容、端口、预测/转发结构或接受语义可能产生另一设计。本文只验收 I=5/6，不允许直接改常数声称支持更短间隔。

## 11. 原子提交、转发与生命周期证明

### 11.1 描述符与原子性

事务包含 payload、epoch/bank、n/p/successor、旧值快照、各写目的地址/enable/data、head/cache/bank/计数变化及响应预留身份。E_P 先寄存主体，E_C 补齐末级并同步形成最终描述符。

提交沿的统一 commit_enable 必须同时控制全部正常状态变更和当沿 RAM 写。提交前不可把 TT/marker 或链路提前暴露给后续事务。接受阶段只允许记录上下文、预留容量/响应信用和更新 RR/冷却。

已提交未物理完成的 NEXT[p] 写属于权威逻辑状态，读者必须按 overlay 解释。若只是写了一半链表再等下一拍才宣布完整，不符合本规范。

### 11.2 快照为什么有效

相邻接受沿至少相隔 I，插入在 I-1 提交、出队在 1 提交，均早于下一次接受。当前搜索至提交期间不存在另一事务的逻辑队列修改；旧事务只可能完成已经提交的 NEXT 修补。

所以当前事务 E0～E1 取得的 RC、L1/L2、精确 L3 和 bank 状态属于同一个已提交队列状态，备用叶稍后读取也不被并行 metadata 写改变。精确叶快照不能被备用叶 q 覆盖，否则置位会写错叶字。

此性质使任意热点键可固定时延完成，无锁等待或重试；合法流量不允许通过内部 stall 补救实现错误。

### 11.3 转发与退休

所有读按“当前沿新提交 > 最新 pending 已提交 > RAM q”选择逻辑值，并绑定 read_valid、地址和事务身份。无效指针/清零写也属于有效转发内容。

旧插入在 E_I 写 NEXT[p] 后，其 overlay 保留到 E_(I+1)；E_I 发出的同址读必须已捕获 bypass_data 并传给消费阶段。不能在退休沿清 valid，导致尚待本沿使用的 q 失去旁路。

最终写回 descriptor 可保留整项字段，物理每次写完后记录 pending mask，禁止重复修补已完成地址。转发匹配包含 RAM 身份和完整地址。

### 11.4 相邻事务冲突规则

| 冲突 | 必须行为 |
| :--- | :--- |
| 相同键连续插入 | 后者读新 RC/TT tail，追加到前者之后 |
| 不同键共用叶/父 | 后者快照包含前次置位/清位，不丢兄弟 bit |
| 上次插入改变此次前驱 | 此次重新查找已提交的新树 |
| 前驱等于 head | 提交时同步修补 head_cache.next |
| 旧 NEXT 写与新预取同址 | 读沿捕获旁路，下一沿返回新链路 |
| 最后同键删除后再次插入 | 看到 RC=0、TT 无效、marker=0 |
| 旧 bank 清空后重用 | 精确 metadata 已归零，建立新的完整 bank_epoch |
| 满队列同时请求两操作 | 本次只出队，后次发射才用释放地址 |
| FIFO 背压 | 信用耗尽停止出队接受，合格插入仍可发射 |

### 11.5 指针释放与上下文容量

设插入 T0 在 t 接受，其最后节点写在 t+I；紧接出队 T1 最早在 t+I 接受，于 t+I+1 释放原头。释放之前 T0 节点写已完成，T1 不会删除一个尚未提交插入所依赖的前驱。

下次可能分配该地址最早在 t+2I，此时 T0 已于 t+I+1 退休，且 t+2I>t+I+1。因此旧 NEXT 写不能覆盖新分配节点；不需要靠额外代数标签规避地址 ABA。

最大存活时长为插入 I+1 拍，小于两次发射间隔 2I，所以两个上下文足够。全局 t+I+1 可能同时退休 T0 并提交 T1 出队，控制器必须支持该同时事件；响应 FIFO 生命周期不占事务上下文。

上述证明同时适用于 I=5/6，依赖本文全部提交/修补沿和准入规则，不适用于独立改小 I 或延后写回。

## 12. 时钟、复位与初始化

### 12.1 时钟与复位

功能逻辑及全部存储共用 clk，无内部 CDC、RAM 倍频或多相端口借用。rstn 低有效，控制寄存器异步复位、内部复位同步释放；建议统一两级释放同步器，内部模块不得各自独立释放。

复位清流水 valid、缓存/响应 valid、fault 和正常运行写使能。大 RAM 使用扫描初始化，不能在异步 reset 分支全数组清零而破坏宏推断。

### 12.2 初始化序列

~~~text
META_DEPTH  = EPOCH_BANKS * (2**TAG_WIDTH) = 8192
INIT_WRITES = max(META_DEPTH, MEM_DEPTH)
~~~

第一个内部初始化写沿记为 R0，i=0；每沿 i 加一，所有下列独立存储可并行写：

| 条件 | 写入 |
| :--- | :--- |
| i<META_DEPTH | RC[i]=0，TT[i]={0,0} |
| i<2 | L1[i]=0 |
| i<32 | L2[i]=0，唯一寄存器状态 |
| i<512 | L3[i]=0，单端口只执行写 |
| i<MEM_DEPTH | FREE[i]=i |

L1/L2 可以在复位时额外清零，但保留表中扫描过程不改变初始化契约。DATA/NEXT 不需要清零；无有效指针允许访问它们，插入在暴露节点前完整初始化其 DATA/NEXT。

R_(INIT_WRITES-1) 是最后写沿；R_INIT_WRITES 为 guard，在此沿设置 free_count=MEM_DEPTH、queue_level=0、alloc_reserved=0，作废全部 bank/head/tail/cache，清上下文/响应/冷却、恢复 RR 初值并置 init_done=1。**第一次可能接受在下一沿 R_(INIT_WRITES+1)。**

默认最后写为 R8191、guard 为 R8192、最早接受为 R8193。初始化占用 8192 写沿加 1 guard；按 8193 周期预算约为 32.772 μs@250 MHz、54.620 μs@150 MHz，外部复位同步释放时间另计。epoch 正常推进不重新初始化。

### 12.3 初始化期间与运行中复位

初始化期间 insert_ready/extract_ready、所有 commit、extract_val、busy、idle、full、insert_epoch_blocked 为 0；queue_level=0、empty=1。请求方可保持 valid 等待，未握手的脉冲不在初始化后重放。

运行中复位取消全部队列内容、在途请求和未消费响应，重新执行完整初始化，不承诺保存复位前接受的数据。系统两端须协调同一复位恢复语义。初始化写与正常写互斥，防止旧流水回写污染清表。

## 13. 异常、协议与 fail-stop

### 13.1 正常背压

初始化、发射冷却、容量不足、空队列、响应信用不足、epoch 超窗和 RR 未获授权均为正常背压，不置 fault。未接受请求不分配、不删除、不改 metadata、不生产响应。

输入线宽无法检测上游把更宽 tag 错误截断的行为；tag/epoch 生成正确性属于上游。请求被背压时须保持有效及 payload，响应被背压时 DUT 须保持有效及 payload。

### 13.2 故障编码

以下为正常数据通路可实施的局部检查，检测后阻止出错事务提交并锁存 sticky fault：

| fault_code | 含义 |
| :--- | :--- |
| 0 | 无错误 |
| 1 | RC 上/下溢：插入 old_RC>=MEM_DEPTH，或出队 old_RC=0 |
| 2 | 查找/metadata 矛盾：有效同代前驱的 TT 无效、trie_exact 与 old_RC 非零不等价、有效备用叶为空，或出队精确路径 marker 缺失 |
| 3 | 必要链路/缓存有效性与计数不符，如非空无 head、多节点无 head.next、非法空 successor |
| 4 | bank_epoch/角色/计数与有效区段不符，或预取下一头 epoch 与预期 bank 不符 |
| 5 | 容量、预留、bank 或响应信用计数越界 |
| 6 | 无可用上下文、阶段 valid/事务归属错误、非法端口冲突 |
| 7～15 | 保留 |

code=3 的 successor 判定必须结合计数/边界：插入在 global tail 后得到 NULL 是合法情况。对未被选中的 speculative 候选不解引用 TT/NEXT。

若同一检测沿有多个错误，取数值最小非零编码；已有 fault 后保持首次锁存编码。局部检测逻辑必须在相应写入/提交沿前形成 inhibit，不能先让部分写生效再于沿后报告错误。

禁止部分逻辑提交：出错事务的 RAM 写、寄存器更新、提交脉冲、响应入队及释放地址必须由同一个有效提交条件屏蔽。此前接受阶段已形成的预留可留到复位清理，不能为维持固定完成承诺继续使用损坏状态。

### 13.3 fault 后行为与验证责任

fault 后禁止新接受和未完成事务继续提交；保留此前已提交的响应，允许下游消费。尚待完成的物理写回不再构成可继续服务的承诺，恢复必须复位并完整初始化。

固定时延、吞吐及完成保证适用于无复位/fault、协议合法的工作区间。正常热点、bank 重用或合法同址读写不能触发 fault 来替代正确处理。

硬件不要求逐拍扫描全链表/全 RC/FREE。无环、全表计数和空闲地址唯一性由验证检查器/形式性质覆盖；fault 编码不等于对任意存储损坏提供完整容错。

## 14. 验证计划与验收

### 14.1 独立功能参考

参考模型使用稳定排序队列，元素为 {未截断逻辑 epoch,tag,insert_accept_sequence,flow_id}：

1. 测试端先产生未截断 epoch，再编码 16 bit 驱动 DUT，避免参考模型重复 bank/epoch 回绕错误。
2. insert_fire 记录输入，在该配置规定的 E_C 加入参考队列。
3. extract_fire 对应 E1 删除参考最小项，并进入独立预期响应队列。
4. rsp_fire 比较完整 payload；相同 payload 的多实例仍须按插入序号验证内部关联。
5. 每次提交后对比 queue_level、bank、RC/TT/Trie 和 overlay 后逻辑链表。

不能对全部历史响应简单断言 tag 单调，因为出队后可以新插入更小键。物理 RAM 在 pending NEXT 修补期间允许与逻辑链表不同，检查器必须应用已提交 overlay。

### 14.2 单元验证

| 单元 | 验收覆盖 |
| :--- | :--- |
| matcher16 | 全部 65536 bitmap×16 query 的 LE/LT；全 bitmap 的 MAX；found/index/onehot/exact |
| upper regs | 单份状态、地址改变无需时钟即可改变读值；同步写沿前/后语义；两个配置的 C 候选一致 |
| Trie search | 与集合 max(y<=x) 独立比较；A/B/C/无前驱、两 bank、稀疏树、完整 exact |
| L3 wrapper | 真正 1RW，read latency=1；禁止同沿读写；read_valid 与请求地址对应 |
| 1R1W wrapper | 同沿同址/异址、RAM 不同 read-during-write 模式、NULL/0 转发、退休与读消费同沿 |
| RC/TT | 0/1/2/MEM_DEPTH 边界、同值尾、最后键删除 |
| FREE | 全容量分配释放、地址 0/最大值、重分配及容量预留 |
| commit/context | 主体提前寄存、末级直接提交、两上下文、retire/enqueue 同沿、pending 生命周期 |
| FIFO | 空/满/预留、同沿入出、连续背压、沿后 valid 与消费沿 |
| epoch | 相邻代、65535→0、第三代背压、旧 bank 清空复用、队列空后任意首代 |

### 14.3 顶层定向用例

以下均对 I=5 和 I=6 执行，时序检查使用派生常量。

| ID | 场景 | 关键结果 |
| :--- | :--- | :--- |
| F01 | 复位、初始化、第一项插入/出队 | R8191/R8192/R8193 边界准确，头缓存建立/清空 |
| F02 | 任意顺序插入 tag 0、4095 和中间值 | 同代无符号升序 |
| F03 | 不同 Flow ID 的同键反复插入 | FCFS，TT 指同值尾 |
| F04 | 4096 个同键填满再排空 | RC=4096 可表示，最终全部计数/marker 归零 |
| F05 | 删除同值组第一项、中间项、最后项 | 只在最后项清 TT/Trie |
| F06 | 清叶但父有兄弟、清父但根有兄弟 | 精确清理，兄弟不丢失 |
| F07 | {0x1FF,0x250,0x300} 插入 0x240 | C 返回 0x1FF，仅一个备用叶读 |
| F08 | {0x210,0x250} 插入 0x240 | B 返回 0x210，不读取 C 叶 |
| F09 | {0x245,0x249} 插入 0x247 | A 返回 0x245，无备用叶读 |
| F10 | 最小 tag=100 后插入 0 | 无前驱，新全局头 |
| F11 | 在 head 后插入，下次立即出队 | 缓存 next 已修补 |
| F12 | 单节点后插相同/更小 tag，再出队 | 头尾/重复顺序正确 |
| F13 | 旧代 4090/4095、新代 0/10 交错到达 | 旧代全部先服务 |
| F14 | 两代同数值 tag | RC/TT 分离 |
| F15 | 65535→0→1，多次复用 bank | 无历史 metadata 污染 |
| F16 | 第三代 valid 保持，持续出队 | 不饥饿，推进后接受 |
| F17 | 满/空时两类同时请求 | 不预支同拍释放，不同时接受 |
| F18 | 两路持续合格 | RR，每 I 拍聚合接受一次 |
| F19 | 最后键删除后同键重插和地址重用 | 无陈旧 TT、无环、无旧写覆盖 |
| F20 | 下游长期背压 | 两槽信用用尽后停止出队，响应稳定 |
| F21 | 老响应未消费而队列排空并重建 | 响应不受地址/bank 重用影响 |
| F22 | 第 10.5 节 A→B→C 插 D 再出 A | E_I 同址 NEXT[B] 旁路得到 D |
| F23 | E_C/E_I/E_R 邻近复位 | 无幽灵提交，重新初始化 |
| F24 | 局部 TT/RC/marker/cache 故障注入 | 编码、提交抑制及复位恢复正确 |
| F25 | FAST5 前视与 PIPE6 分割搜索对比 | 同一状态/输入结果相同，read_en 数量/沿正确 |
| F26 | 连续 2/3/4 个任意操作组合 | 单端口不超用、两上下文足够、无请求后停顿 |
| F27 | 空响应 FIFO 接受出队，下游一直 ready | E1 沿后 valid，最早 E2 消费 |
| F28 | 路径候选无效且索引为 0、bit0/bit15 边界 | found 与 index 分离，无错误备选 |
| F29 | 精确叶与备用叶不同，连续同父多键操作 | 更新使用精确叶快照，不把备用 q 写回精确地址 |
| F30 | 两配置分别综合和时序检查 | 记录逻辑成本、实际 f_max、f_max/I 与共同瓶颈 |

F24 用 testbench 后门、bind 或仿真 force/release 注入实际被读取的状态；若 overlay 会遮蔽 RAM 注入，应明确注入位置和生效周期。正常功能接口不新增 fault_inject 端口。测试至少包括提交沿前可见错误和同沿多错误优先级。

### 14.4 随机验证与覆盖

每配置在默认容量下至少 10 个独立种子、每种子 100,000 次已接受操作，末尾排空队列并消费全部响应。此项为未来 RTL 验收要求，附录 C 的规格模型运行量不替代它。

激励包含均匀/热点/同值 tag、递增递减、极值交错、少量活跃前缀、多 Flow ID、随机请求间隙、比例偏斜、随机响应背压、两代交错和连续 bank 重用。

功能覆盖至少交叉：配置×操作×空满状态×新键/重复×A/B/C/无前驱×bank 角色×清除层级×head/tail 关系×响应信用×相邻操作组合×NEXT RAW。

小容量（MEM_DEPTH=16/32）增加满空转换和有界形式检查；默认容量完整执行 F04。PTR_WIDTH=4/12/16、FLOW_ID_WIDTH=8/9/12 至少做 elaboration 和相应容量边界检查，最大容量初始化必须使用派生 INIT_WRITES。

### 14.5 关键断言

在 init_done 且无 reset/fault 的正常区间：

1. 每沿最多一个 fire，相邻 fire 间隔至少 I；持续合格时不插入额外气泡。
2. 每个 insert_fire 恰好对应 E_C 一次提交，extract_fire 恰好对应 E1 一次提交；不允许无请求或重复提交。
3. 提交/退休时正确释放唯一预留/上下文；最多两个上下文，退休已完成写且已交接读旁路。
4. `free_count+alloc_reserved+queue_level==MEM_DEPTH`，所有计数范围合法。
5. bank_count 总和等于 queue_level，每 bank RC 总和等于 bank_count。
6. RC 非零、TT.valid、叶 marker 等价；父/根等于下层归约 OR。
7. TT 指向 live 同键尾；链表无环、有序、计数准确、tail.next=NULL。
8. live/FREE 有效栈/预留地址互斥且覆盖全部物理槽位。
9. head_cache 等于 overlay 后的逻辑 head 节点，包括 next；head 无效则缓存无效。
10. `rsp_count+rsp_reserved<=2`；无预留不得生产响应；背压时输出稳定。
11. 活跃 bank 的完整 epoch 仅为 base/base+1，bank parity 与 epoch 匹配。
12. L3 每沿 R+W<=1；其他 RAM 每沿 R<=1、W<=1；L1/L2 无状态副本且每层每沿至多一个字写。
13. 每个 q 只供其 read_valid/事务/地址使用；E_I 读的旁路不可因 E_R 退休失效。
14. trie_exact 等于该事务保存的 old_RC!=0；更新基于精确路径快照。
15. E_C 之前无本事务逻辑链路/metadata 修改；E_C 所有逻辑变更原子可见。
16. 无 fault 时 E_I 前驱修补及 E_R 退休固定，不以热点或分支结果延后。

全量状态性质可以放在 testbench/bind，不要求变成综合扫描硬件。断言按实际寄存器采样/NBA 编写，不能把沿后脉冲错误地解释成下一拍才提交。

### 14.6 完成标准

RTL 功能交付须完成编译/lint、单元与顶层仿真、上述定向/随机测试和无未解释断言失败；综合后确认存储结构、端口、寄存器与流水延迟。频率/吞吐交付另须实际宏或器件模型、约束及 STA 证据。

规格 Python 模型用于检查算法、排程和状态一致性，不能证明 RTL 编码、X 传播、复位电气行为、宏碰撞模式或时序收敛。当前已完成范围见附录 C。

## 15. RTL 实现与时序约束

### 15.1 编码和存储映射

使用可综合 SystemVerilog，组合/时序块分离；组合块给全默认值，禁止 latch，时序状态使用 nonblocking。mask/计数/指针算术显式定宽，invalid link 不寻址。

L1/L2 使用 `logic [15:0] l1_regs[2]`、`logic [15:0] l2_regs[2][16]` 或等价寄存器结构。正常更新是时钟沿写指定字；读端是组合选择。不能包进强制 1 拍读的 RAM wrapper，也不能为了“统一接口”额外寄存其读输出。PIPE6 的 aC/候选寄存属于明确的算法流水边界。

L3 使用独立的 1RW wrapper，技术映射保持 read latency=1，无隐藏输出级、双泵或完整读副本。DATA/NEXT 分离；其他表使用明确 1R1W wrapper。初始数据、位宽填充、物理深度浪费、ECC/DFT 开销在综合报告另列。

FAST5 的 max_b 是对单份寄存器字的组合预计算；不要把为读取带宽复制状态与纯逻辑扇出缓冲混为一谈。综合后的面积报告应单列上层状态、前视组合逻辑、流水/上下文以及 SRAM 宏面积，不能用第 6.2 节逻辑 bit 节省直接等同于总面积或功耗节省。

### 15.2 必须检查的单周期路径

| 配置 | 路径 |
| :--- | :--- |
| FAST5 | E0 输入寄存器 → 根 LT/各父 MAX 并行 → 编码选择 → 备用叶地址 |
| FAST5 | 精确 L3 q → A 的 LE/found → B/C 选择 → E1 备用读地址建立 |
| PIPE6 | E0 → A/bB/aC 寄存；E1 aC → L2 mux/MAX → E2 备用读 |
| 两者 | 备用 L3 q → MAX/前驱选择 → TT 地址 |
| 两者 | TT q → valid/全局前驱选择 → NEXT 地址 |
| 两者 | NEXT q → successor 字段/局部检查 → E_C 提交写口和缓存 D |
| 两者 | 出队 RAM q → RC/精确清位/下一头检查 → E1 提交 |
| 两者 | pending/同沿写地址比较与旁路 → 下一头缓存 |
| 两者 | valid/资源/epoch/RR → ready 与接受沿控制 |

ISSUE_INTERVAL 是吞吐约束，不是允许所有路径跨 I 拍的 timing exception。上述相邻沿数据路径默认单周期，不得统一设成 5/6/8 拍 multicycle。输入直达 E0 RAM 地址的路径要有正确 input delay 和接受门控约束。

### 15.3 频率不满足时

先根据报告定位路径，在保持本文边沿契约下优化分组 matcher、选择器、扇出和布局。FAST5 上层不收敛时可编译 PIPE6，并按第 10.6 节比较 f/I。

PIPE6 若卡在公共出队/提交末级，不能仅凭多一拍假设已经解决；应选择满足约束的频率，或另立规格修改提交时延、端口/存储内容和指针生命周期。不得在 RTL 中悄悄插一拍而继续报告本文的完成时延。

### 15.4 集成责任

功能模块负责顺序、准入、固定提交和响应；系统负责合法 epoch、同流描述符与包 FIFO 对应、复位协调和上下游协议。技术 wrapper 负责真实 SRAM/BRAM 延迟、碰撞旁路配合及 DFT 模式隔离。

后续选择具体工艺/FPGA、宏和工具后记录实际配置与约束。本文不预先承诺某个宏名称、最终面积、功耗或时钟结果。

## 16. 需求追踪与冻结项

### 16.1 需求到验收

| 需求 | 规范位置 | 主要验收 |
| :--- | :--- | :--- |
| 稳定排序、重复键 FCFS | 3、8、9 | F02～F05、参考队列 |
| 两代跨回绕共存 | 3、9 | F13～F16、F21 |
| 单份上层寄存器、组合读 0 拍 | 6、7.4～7.5、15 | upper regs 单测、F25、综合结构 |
| L3 单份单端口、同步读 1 拍 | 6、7.3、10.5 | wrapper 单测、F07～F09、F26 |
| 唯一备用叶，无状态复制 | 7 | 前驱集合对比、端口断言 |
| 默认 II=5、可选 II=6 | 2、10 | F18、F25～F26、F30 |
| 固定提交、原子逻辑状态 | 10～11 | 周期断言、overlay 后全状态比较 |
| LAST-key 精确清理 | 7.7、8 | F04～F06、F19 |
| 指针重用和 NEXT 旁路 | 9～11 | F11、F19、F21～F22 |
| 响应背压/生产沿 | 4、10.3 | F20～F21、F27 |
| 初始化和故障隔离 | 12～13 | F01、F23～F24 |
| 参数计数/资源正确 | 2、6 | F04、参数 elaboration |

### 16.2 V1.1 冻结决定

冻结 12-bit tag、16-bit epoch、两个相邻代 bank、共享节点池、同值尾 TT、足宽 RC、精确 marker 清理、单向全局链表及完整头缓存。

冻结 L1/L2 单份寄存器 0 拍组合读、L3 单份 1RW 同步 1 拍读；冻结 FAST5 默认与 PIPE6 可选的完整排程、出队 E1 提交、两上下文及两项响应 FIFO。冻结接受后无正常内部停顿/回放、提交早于下一次接受、NEXT 修补及旁路生命周期。

### 16.3 需要后续版本的变化

超过两代共存、tag 宽度/Trie 分层变化、运行中切换 I、I 不为 5/6、接受同拍双操作、提交/退休沿改变、L3 多端口或倍频、任意删除/peek/packet ID 接口都需要重新设计相应协议和证明。

具体器件/工艺映射、布局和逻辑优化可在不改变上述契约的条件下推进，无需把实现选择当成未冻结的功能分支。

### 16.4 版本记录

| 版本 | 内容 |
| :--- | :--- |
| V1.0 | 初始完整基线：显式 epoch、RC 修正、重复读副本和 II=8 |
| 0911 评审分析 | 资源公式、响应沿语义、故障注入与验证说明 |
| 0915 副本分析 | 精确路径早读和唯一备用叶，证明副本非必要 |
| V1.1 | 上层单份寄存器、底层单份 1RW；FAST5/PIPE6、末级提交及更新后的生命周期/性能证明 |

## 附录 A：操作伪代码与阶段常量

~~~text
I = ISSUE_INTERVAL                 // 5 or 6 only
B = I-4; T = I-3; P = I-2
C = I-1; PATCH = I; R = I+1

on insert_accept(E0):
    save payload and current bank/head/tail state
    reserve FREE top; read FREE, RC[input_key], L3[exact_prefix]
    evaluate upper register paths for selected configuration

on E_B:
    if !A_found:
        read exactly one B/C leaf if its prefix is valid
on E_T:
    select same-epoch predecessor
    read its TT if valid; otherwise choose old-bank tail or NULL
on E_P:
    read NEXT[p] if p.valid
    latch all successor-independent commit fields
on E_C:
    complete successor-dependent fields from returned NEXT / saved head
    if all checks pass:
        atomically commit list, RC, TT, Trie, cache, bank and counts
        write DATA[n], NEXT[n], metadata
        retain logical NEXT[p]={1,n} in pending descriptor
on E_PATCH:
    physically write NEXT[p] if p.valid
on E_R:
    retire after bypass handoff

on extract_accept(E0):
    reserve response slot; save current head_cache
    read old-head RC/L3 and next-head DATA/NEXT
    combinationally read old-head L1/L2
on E1:
    if all checks pass:
        atomically remove head, precisely update metadata/banks/cache
        return pointer to FREE and enqueue full response payload
on E2:
    retire; response remains until downstream handshake
~~~

上述 on E_C 表示写口在该沿前已完成组合准备，不能在该沿才开始一个额外寄存流水级。

## 附录 B：实现审查易错项

1. 把 read latency=0 解释成无门延迟，或把 L1/L2 再包一层同步读。
2. 把两个 epoch 的不同状态 bank 当成副本；把组合 max_b 当成需要维护的存储表。
3. 唯一 L3 仍按 A/B/C 三叶并发寻址，或同拍读写借用双端口。
4. 只修改 I，却保留旧 E7/E8/E9 提交/修补/退休。
5. E_C 锁存完整 descriptor 后又等一拍提交，导致契约错位。
6. FAST5 使用根 LT→全 L2 mux→MAX 的串行结构却沿用未验证的频率估计。
7. 备用叶 q 覆盖精确叶快照；更新写错叶内容。
8. 用局部 exact 代替完整键 exact；用 index=0 代替 found=0。
9. 12-bit RC/free_count 无法表示 4096；count 截断后再检查边界。
10. TT 指向组首、同值第一次出队便清 TT/marker、遗漏地址中的 bank。
11. 修补 NEXT RAM 却忘记 head_cache.next，或只有缓存修补而漏掉 B 节点预取 RAW。
12. E_I 写完即清 overlay，E_R 消费的同步读丢失旁路；NULL 写不参与转发。
13. 新代小 tag 越过旧代尾成为全局最小；直接无符号比较拼接 epoch/tag。
14. 旧响应在地址重用后重新读 DATA；把响应消费当作再次释放地址。
15. FIFO 原空时把 valid 推迟到 E2 沿后；或在 E1 沿已要求消费刚产生的寄存响应。
16. 初始化 guard 与最早接受少算/多算一拍；未完成初始化就检查全容量不变量。
17. 为闭合时序盲目设置所有路径为 I 拍 multicycle。
18. 用 f/I 宣称均衡包服务率，或用逻辑 bit 数节省宣称等比例总面积节省。

## 附录 C：本版本已执行的规格模型检查

仓库新增 [model/wfq_v11_check.py](model/wfq_v11_check.py)，使用 Python 3 标准库；导入既有 [model/wfq_trie_single_copy_check.py](model/wfq_trie_single_copy_check.py) 的基础 Trie 辅助函数，对比答案由独立有序集合/稳定参考队列产生。

在仓库根目录运行：

~~~powershell
py -3 -B model/wfq_v11_check.py
~~~

本次实际通过结果：

| 检查 | 已执行范围与结果 |
| :--- | :--- |
| 前驱与配置等价 | 71 组键集合×4096 个 query×2 bank×2 配置，共 1,163,264 个 query/profile 组合通过 |
| 最坏端口排程 | 两配置的全部 2/3/4 操作类型序列，共 56 组通过 |
| FAST5 周期模型 | 10,068 个混合/排空已接受操作；53 次同沿 NEXT RAW；全部响应一致 |
| PIPE6 周期模型 | 10,068 个混合/排空已接受操作；54 次同沿 NEXT RAW；全部响应一致 |
| FAST5 默认满容量 | 4096 同键填满再排空，8192 次操作通过 |
| PIPE6 默认满容量 | 4096 同键填满再排空，8192 次操作通过 |

周期模型区分物理 RAM、同步读返回、逻辑提交、pending NEXT 修补、读沿旁路、地址分配/释放、头缓存、两代状态、响应预留和消费；包含确定的 NEXT 同址场景、热点输入、跨代及随机响应背压。

上述结果支持“单副本及 5/6 拍排程在本规格状态模型上自洽”。模型没有实现完整 RTL 故障注入、初始化电气时序、所有参数组合和第 14 节全部验收，也没有进行 RAM 宏仿真、综合、STA 或功耗评估；不能据此把目标 MHz 写成实测性能。
