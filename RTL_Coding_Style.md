# RTL Coding Style（Verilog 编码规范）

| 项目 | 内容 |
|------|------|
| 版本 | v1.7 |
| 日期 | 2026-09-02 |
| 适用范围 | `rtl/` 目录下所有新增及修改的 Verilog 源文件（`.v` / `.vh`） |

## 版本记录

| 版本 | 日期 | 变更 |
|------|------|------|
| v1.0 | 2026-09-02 | 初版：接口列对齐、声明/赋值分离、begin...end 换行缩进、模块体取消首层缩进 |
| v1.1 | 2026-09-02 | 新增 §5：模块实例化的对齐与换行规范 |
| v1.2 | 2026-09-02 | 删除外部参考示例目录 `coding_style_for_ref/`，移除全部引用；本文件内嵌示例即为风格基准 |
| v1.3 | 2026-09-02 | 新增 §6：逻辑分区与就近组织（信号局域性）；修订 §2.5 为"全局信号集中声明、强关联组就近声明"两层结构 |
| v1.4 | 2026-09-02 | 新增 §7：时序逻辑复位风格（异步复位、同步释放、低电平有效 rstn，存储器例外） |
| v1.5 | 2026-09-02 | 新增 §8 命名规范；§1.9 升级为"单文件统一对齐竖线"（接口/声明/实例化同列）；§0 新增单文件单 module |
| v1.6 | 2026-09-02 | §1.9 竖线加下限：对齐列列号 ≥ 40；位宽 `]` 与信号名至少间隔 4 空格，不足则整体右移（如 50） |
| v1.7 | 2026-09-02 | 新增 §8.4：时序寄存器后缀命名（`_d`，纯打拍 `_d1`/`_d2`…）；§7.1 复位值放宽为允许裸 `0`/`'0`；内嵌示例同步改名 |

后续所有 RTL 编码（包括人工编写与工具生成）**必须遵守**本规范。本文件内嵌的代码示例即为风格基准；新增代码与本文件不一致时，以本文件为准。

---

## 0. 基础约定

1. 缩进一律使用**空格**，不用 Tab；每个缩进级别为 **4 个空格**。
2. 每行**行尾不得残留空白字符**。
3. 文件必须以**换行符结尾**（EOF newline）。
4. 使用 Verilog-2001 或以上标准（端口声明带 `input wire` / `output reg` 等完整类型）。
5. 文件头保留现有注释块格式（`Project / File / Spec / Function ...`），位于 `` `timescale `` 之前。
6. **单个文件只允许定义一个 module**，不允许同一文件定义多个 module；文件名与模块名一致（`<module_name>.v`）。

---

## 1. 模块接口声明：列对齐

### 规则

1. `parameter` 列表与端口列表 `( ... );` 内保持 **4 空格缩进**（这是全模块唯一保留首层缩进的部分，见 §4）。
2. 每个端口按**三列**对齐，同一端口表内所有端口行对齐到相同列：

   ```
   方向（input/output） │ 类型 + 位宽（wire/reg [..]） │ 信号名
   ```

3. **方向列**：`input` / `output` 后补 1–2 个空格，使其后的 `wire` / `reg` 关键字对齐（`input` 6 字符、`output` 7 字符，故 `input` 后用两个空格）。
4. **位宽列**：以整个端口表中**出现的最宽位宽说明**为基准，窄的右侧补空格；无位宽的端口（如 `clk`）同样补齐到信号名列。
5. **信号名列**：所有端口名左对齐于同一列。
6. 功能相关的端口分为一组，组与组之间用**空行 + `//` 注释行**分隔。
7. 端口表最后一个端口**不带逗号**。
8. `parameter` 列表中的 `=` 同样对齐。
9. **单文件统一对齐竖线**：同一文件内，以下三处必须对齐到**同一列**——模块接口声明的信号名列、模块体内所有 wire/reg 声明的信号名列、所有实例化连接与参数覆盖的左括号列。该列须同时满足：
   - **列号不小于 40**（基线为 40；若第 40 列落在某个信号的位宽声明 `[...]` 上而不是空白，则整个对齐列右移，比如移到 50）；
   - **位宽声明的右方括号 `]` 与其后的信号名之间至少间隔 4 个空白符**（底线）。

   即对齐列 = `max(40, 全文件最宽位宽声明右括号的结束列 + 5)`。实例化 `.port_name` / `.PARAM` 名与左括号之间至少留 1 个空格。`integer` / `genvar` 声明建议跟随同一竖线。

### 示例

```verilog
module trie_level_reg #(
    parameter NODE_CNT  = 16,     // 1 for Level-1, 16 for Level-2
    parameter ROOT_MODE = 0      // 1 = Level-1 semantics for clean_en
)(
    input  wire                        clk,
    input  wire                        rstn,

    // full combinational read-out: node i occupies bmp_flat[16*i +: 16]
    output wire [NODE_CNT*16-1:0]      bmp_flat,

    // marker set (Spec §5.2.2 insert path, CYC4)
    input  wire                        set_en,
    input  wire [3:0]                  set_node,   // folded to 0 in ROOT_MODE
    input  wire [3:0]                  set_bit,

    // marker clear (Spec §5.2.2 zero-ref cascade, CYC3)
    input  wire                        clr_en,
    input  wire [3:0]                  clr_node,   // folded to 0 in ROOT_MODE
    input  wire [3:0]                  clr_bit,

    // sliding-window zone clean (Spec §10.4, single-cycle pulse)
    input  wire                        clean_en,
    input  wire [3:0]                  clean_idx
);
```

---

## 2. wire / reg 声明与赋值分离

### 规则

1. **禁止在声明行直接赋值**，即禁止以下写法：

   ```verilog
   wire [3:0] set_idx = (ROOT_MODE != 0) ? 4'd0 : set_node;   // ❌ 禁止
   ```

2. 必须拆分为**声明行 + 独立赋值行**：

   ```verilog
   wire [3:0] set_idx;                                        // ✅ 声明
   ...
   assign set_idx = (ROOT_MODE != 0) ? 4'd0 : set_node;       // ✅ 赋值
   ```

3. 组合逻辑用 `assign`（或 `always @*`）赋值，时序逻辑在 `always` 块内赋值；声明行只做声明。
4. 存储器声明（`reg [15:0] node [0:NODE_CNT-1];`）同样不带初始化；上电初始化放在独立的 `initial` 块中完成。
5. 模块体内**声明在前、赋值在后**。此规则适用于**全局/跨分区信号**：集中在模块体顶部的声明区，按类别分组并保持空行分隔（存储器/reg → 内部 wire → `integer`/`genvar`），必要时加注释；其 `assign` 语句与 `always` 块置于顶部声明区之后。**强关联信号组**可按 §6 就近声明于所属功能分区内，不受"顶部集中"约束。
6. 声明的信号名列必须落在 §1 规则 9 的**文件级统一对齐竖线**上，不按组局部对齐。

### 示例

```verilog
reg [15:0]                             node [0:NODE_CNT-1];

// ROOT_MODE folds all node indices to node 0 (constant, elaboration-safe)
wire [3:0]                             set_idx;
wire [3:0]                             clr_idx;

integer                                ii;

assign set_idx = (ROOT_MODE != 0) ? 4'd0 : set_node;
assign clr_idx = (ROOT_MODE != 0) ? 4'd0 : clr_node;

always @(posedge clk or negedge rstn) begin
    ...
```

---

## 3. begin...end 语句块：换行与缩进

### 规则

1. `begin` 与控制语句**同行**：`if (...) begin`、`for (...) begin`、`always @(posedge clk) begin`、`initial begin`。
2. `end` **独占一行**，与其所属控制语句左对齐。
3. **条件与语句体必须分行**：即使语句体只有一条语句，也必须另起一行并再缩进一级；单语句体可省略 `begin...end`，多语句体必须使用 `begin...end`。

   ```verilog
   if (wen)                                  // ❌ 禁止：条件与语句体同行
       mem[waddr] <= wdata;                  // ✅ 语句体另起一行，再缩进一级
   ```

4. `else` / `else if (...)` **独立成行**，紧跟在上一分支的 `end` 之后（`end` 与 `else` 不同行），并与对应的 `if` 对齐：

   ```verilog
   if (!rstn) begin
       ...
   end
   else if (clean_en) begin
       ...
   end
   else if (set_en) begin
       ...
   end
   ```

5. `for` 循环同理：循环头独占一行，循环体（单条语句时）另起一行缩进一级。
6. 同一 `always` 块内的逻辑段落之间可用**空行**分隔（如读逻辑与写逻辑之间）。
7. 推荐（非强制）：并行的同类赋值语句之间对齐赋值操作符与行尾注释，提高可读性。

### 示例

```verilog
always @(posedge clk) begin
    rdata_a <= mem[raddr_a];   // read-first
    rdata_b <= mem[raddr_b];

    if (wen)
        mem[waddr] <= wdata;
end
```

```verilog
always @(posedge clk or negedge rstn) begin
    if (!rstn) begin
        for (ii = 0; ii < NODE_CNT; ii = ii + 1)
            node[ii] <= 16'h0000;
    end
    else if (clean_en) begin
        if (ROOT_MODE != 0)
            node[0][clean_idx] <= 1'b0;      // clear one L1 bit
        else
            node[clean_idx] <= 16'h0000;     // clear whole L2 node
    end
    else if (clr_en) begin
        node[clr_idx][clr_bit] <= 1'b0;
    end
    else if (set_en) begin
        node[set_idx][set_bit] <= 1'b1;
    end
end
```

---

## 4. 模块体取消首层缩进

### 规则

1. **除模块接口声明（§1 的 parameter / 端口列表）外**，模块体内所有顶层构造一律从**第 0 列**开始，不保留 4 空格首层缩进，包括：

   - 声明：`reg`、`wire`、`integer`、`genvar`
   - 赋值与逻辑：`assign`、`initial`、`always`
   - 结构：`generate` / `endgenerate`、`endmodule`

2. 取消的只是**模块体整体缩进一级**；`begin...end`、`for`、`generate` 内部的**嵌套层级缩进仍然保留**（每级 4 空格，见 §3）。

### 示例（正 / 反对照）

```verilog
// ❌ 错误：模块体带 4 空格首层缩进
    reg [15:0] mem [0:NODE_CNT-1];

    always @(posedge clk) begin
        ...
    end

    endmodule
```

```verilog
// ✅ 正确：模块体从第 0 列开始，嵌套内容逐级缩进（声明信号名列落在文件级竖线）
reg [15:0]                             mem [0:NODE_CNT-1];

always @(posedge clk) begin
    rdata_a <= mem[raddr_a];
    if (wen)
        mem[waddr] <= wdata;
end

// flat combinational read-out
genvar                                g;
generate
    for (g = 0; g < NODE_CNT; g = g + 1) begin : g_flat
        assign bmp_flat[g*16 +: 16] = node[g];
    end
endgenerate

endmodule
```

---

## 5. 模块实例化：对齐与换行

### 规则

1. 实例化语句从**第 0 列**开始（遵守 §4），按以下模板**逐行换行**，禁止把多个连接挤在一行：

   ```verilog
   module_name #(
       .PARAM_NAME                         (value),
       .PARAM_NAME                         (value)
   ) u_inst_name (
       .port_name                          (signal_or_expr),
       .port_name                          (signal_or_expr)
   );
   ```

2. **左括号对齐列**：每个 `.port_name (` / `.PARAM_NAME (` 连接表达式的左括号 `(`，与本文件接口声明、变量声明的**信号名列对齐**（§1 规则 9）——即同一条对齐竖线贯穿"端口声明 → 变量声明 → 参数覆盖 → 端口连接"。
3. `.port_name` / `.PARAM_NAME` 统一从 4 空格缩进处开始（第 5 列），名称后补空格使左括号落到对齐列；左括号与表达式之间、表达式与右括号之间**不留多余空格**，写作 `.port_name(expr)` 展开后的对齐形式。
4. **参数覆盖**：`#(` 紧跟在被实例化模块名之后；每个 `.PARAM_NAME(value)` 独占一行；参数表结束行写 `) u_inst_name (`（实例名紧随右括号），与下一部分的端口连接表衔接。
5. **无参数实例化**：省略 `#( ... )` 段，直接写 `module_name u_inst_name (`，端口连接规则不变：

   ```verilog
   select_lookahead_matcher u_m1 (
       .bitmap                             (l1_bm),
       .req_lit                            (lit1),
       .match_found                        (m1_hit),
       .match_lit                          (m1_lit)
   );
   ```

6. 端口连接**每行一个**，按被实例化模块端口声明的顺序排列；最后一个连接不带逗号，收尾 `);` 独占一行、位于第 0 列。
7. 实例名沿用现有命名约定：`u_<功能名>`（如 `u_l1`、`u_m1`、`u_l3`）。
8. 实例化语句置于声明区（§2）之后；大型模块中可按逻辑分区摆放实例，分区用注释条（如 `/////` 横线注释）标记。

### 示例

```verilog
///////////////////////
// wire Declarations
///////////////////////

///////////////////////
// reg Declarations
///////////////////////


trie_level_reg #(
    .NODE_CNT                           (1),
    .ROOT_MODE                          (1)
) u_l1 (
    .clk                                (clk),
    .rstn                               (rstn),
    .bmp_flat                           (l1_bm),
    .set_en                             (l1_set_en),
    .set_node                           (4'd0),
    .set_bit                            (marker_set_tag[11:8]),
    .clr_en                             (l1_clr_en),
    .clr_node                           (4'd0),
    .clr_bit                            (clr_tag_d[11:8]),
    .clean_en                           (win_clean_en),
    .clean_idx                          (win_clean_idx)
);
```

本例中模块自身端口声明的信号名列与全部左括号列均为同一条竖线（上例中为第 41 列），可直接用编辑器的竖线辅助（column ruler）校验。

---

## 6. 逻辑分区与就近组织（信号局域性）

### 规则

1. 模块体按**功能分区**组织，每个分区以横线注释条标题标识（如 `// translation table port scheduling`）。分区的典型粒度：一个被实例化子模块的端口调度逻辑、FSM 状态机、一组功能寄存器（如 head 影子寄存器）等。
2. **强关联信号组就近摆放**：逻辑关联性强的同一组信号——典型判据是**驱动同一子模块端口的控制/数据信号**（通常共享同一前缀，如 `tt_*`、`rc_*`、`ts_*`）——其 wire/reg 声明、`assign` 赋值语句、`always` 语句块、模块实例化应**集中在同一分区内相邻摆放**。
3. **禁止远距离分布**：不得将同一组信号的声明放在文件头声明区、赋值放在中部逻辑区、实例化放在文件尾实例区，迫使读者跨越数百行拼装同一功能。
4. 分区内推荐顺序：**分区标题 → 组内声明（可加 `//` 组注释）→ 空行 → assign / always 逻辑 → 空行 → 实例化（如有）**。
5. **例外——全局信号仍集中在顶部声明区**（§2.5）：被多个分区引用的信号（FSM 状态寄存器及其译码 wire、队列状态、跨分区数据通路寄存器等）不强行下放到某个分区。

### 示例（改造前后对照）

改造前——同一组信号分散三处、相距约 380 行（声明在文件头 L159–193，赋值在中部 L298–306，实例化在文件尾 L537）：

```text
文件头 wire 声明区          中部逻辑区                    文件尾实例化区
wire tt_raddr;      ...    assign tt_raddr = ...;  ...  trans_table #(...) u_tt (
wire tt_waddr;             assign tt_wen    = ...;        .raddr(tt_raddr), ...
wire tt_wen;               assign tt_waddr  = ...;      );
```

改造后——声明、赋值、实例化集中在同一分区内（约 35 行）：

```verilog
///////////////////////////////////////////////////////////////////////////////
// translation table port scheduling
///////////////////////////////////////////////////////////////////////////////
// translation table port control
wire                                   tt_inv_wr_en;
wire                                   tt_ins_wr_en;
wire [TAG_WIDTH-1:0]                   tt_raddr;
wire [TAG_WIDTH-1:0]                   tt_waddr;
wire                                   tt_wvalid;
wire [PTR_WIDTH-1:0]                   tt_wslot;
wire                                   tt_wen;


assign tt_raddr = (cyc1 & ins_act_d) ? trie_pred_tag : ext_tag_d;  // dummy read when idle

assign tt_inv_wr_en = cyc3 & ext_act_d & zero_ref;                 // Spec §5.2.2 TT invalidation
assign tt_ins_wr_en = cyc4 & ins_act_d;

assign tt_wen    = tt_inv_wr_en | tt_ins_wr_en;
assign tt_waddr  = tt_ins_wr_en ? ins_tag_d : ext_tag_d;
assign tt_wvalid = tt_ins_wr_en;                                   // invalidation writes valid=0
assign tt_wslot  = new_slot_ptr;


trans_table #(
    .TAG_WIDTH                         (TAG_WIDTH),
    .PTR_WIDTH                         (PTR_WIDTH),
    .MEM_DEPTH                         (1 << TAG_WIDTH)
) u_tt (
    .clk                               (clk),
    .wen                               (tt_wen),
    ...
    .raddr                             (tt_raddr),
    .rvalid                            (tt_rvalid),
    .rslot                             (tt_rslot)
);
```

---

## 7. 时序逻辑复位风格：异步复位、同步释放、低电平有效

### 规则

1. **所有对寄存器赋值的 always 块（时序逻辑）必须写成异步复位风格**，模板：

   ```verilog
   always @(posedge clk or negedge rstn) begin
       if (!rstn) begin
           <reg> <= <复位常量>;
       end
       else begin
           ...   // 正常时序逻辑，if/else 链按 §3 书写
       end
   end
   ```

   要点：
   - 敏感列表固定为 `posedge clk or negedge rstn`（异步复位：复位立即生效，不等时钟沿）
   - 复位分支必须是**第一个分支** `if (!rstn)`，复位值为**常量**（localparam、位宽匹配的字面量或裸 `0` / `'0`），不得引用其他信号
   - **不允许无复位的寄存器 always 块**：`always @(posedge clk)` 直接对寄存器赋值不合规，pipeline / 打拍寄存器同样必须复位

2. **复位信号低电平有效**，通过命名的 `n` 后缀体现：复位信号名**不限定**为 `rstn`/`rst_n`——前缀可按复位域/功能自由命名，如 `rstn`、`rst_n`、`csr_rstn`、`app_rst_n`，**宗旨是名字以 `n` 结尾、表明低电平有效**。同一模块内同一复位信号的命名保持一致；本规范示例中的 `rstn` 泛指满足该后缀规则的复位信号。

3. **同步释放**（reset removal 同步）：`rstn` 的撤销必须同步到本时钟域，避免 recovery/removal 时序违例。叶子模块按第 1 条书写即可继承该性质；**模块树顶部送入的 `rstn` 必须由复位同步器产生**（异步置位、同步释放），参考实现：

   ```verilog
   // reset synchronizer: async assert, sync release (2-FF per clock domain)
   reg [1:0] rstn_sync;

   always @(posedge clk or negedge rstn) begin
       if (!rstn)
           rstn_sync <= 2'b00;
       else
           rstn_sync <= {rstn_sync[0], 1'b1};
   end

   wire rstn_c = rstn_sync[1];   // synchronized reset for this clock domain
   ```

4. **例外——存储器**：`reg [W-1:0] mem [0:N-1];` 形式的阵列（综合时映射为 ASIC memory 宏 / FPGA 块 RAM）**不加复位**，因为 ASIC memory 宏没有复位信号：
   - 存储器写入按端口风格书写：`always @(posedge clk)`，无复位分支
   - 行为级上电初始化允许使用 `initial` 块（仅用于仿真）
   - 存储器宏行为模型中模拟宏内部数据通路的寄存器（如读出数据寄存器 `rdata`）按宏的真实行为建模，同样不加复位

5. testbench（`tb/`）为仿真环境，不受本条约束。

### 示例

```verilog
// pipeline register: reset required (no unreset sequential blocks)
always @(posedge clk or negedge rstn) begin
    if (!rstn) begin
        pred_ptr_d  <= {PTR_WIDTH{1'b0}};
        pred_form_d <= 1'b0;
    end
    else if (cyc2 & ins_act_d) begin
        pred_ptr_d  <= tt_rslot;
        pred_form_d <= pred_found_d & tt_rvalid;
    end
end
```

```verilog
// memory array: exempt (no reset on ASIC memory macros)
always @(posedge clk) begin
    if (wen)
        mem[waddr] <= wdata;
end
```

---

## 8. 命名规范

### 规则

1. **变量名必须以小写字母开头**：所有 wire / reg 变量名（含端口信号）禁止以下划线 `_`、数字或大写字母开始；名字内部使用小写字母、数字、下划线（snake_case）。模块名、实例名（`u_` 前缀）、generate 块标签、function / task 名同样以小写字母开头。

   ```verilog
   wire _unused_falls;   // ❌ 下划线开头
   wire 2nd_stage;       // ❌ 数字开头
   wire DataIn;          // ❌ 大写字母开头
   wire unused_falls;    // ✅
   ```

2. **大写字母只允许出现在以下三类名字中，且必须全部大写**（不得大小写混合）：
   - `parameter` 名
   - `localparam` 名
   - 名字含义代表**模拟信号**的信号名（如 `AVDD`、`VREF`、`IBIAS`）

   除以上三类外，其余名字（wire / reg / 端口 / 模块 / 实例 / 标签等）一律全小写。

   ```verilog
   parameter WORD_WIDTH = 16;   // ✅ parameter 全大写
   localparam TS_W      = 34;   // ✅ localparam 全大写
   wire AVDD;                   // ✅ 模拟信号，全大写
   wire Avdd;                   // ❌ 大小写混合
   wire rxClk;                  // ❌ 普通信号不得含大写字母
   ```

3. `` `define `` 宏名与 parameter 同级对待，同样全大写（如 `` `TS_ST_CYC0 ``）。

4. **时序寄存器后缀**：always 语句块内（时序逻辑）赋值的寄存器，命名使用 **`_d` 后缀**；**禁止**使用 `_q` 后缀：

   ```verilog
   reg [TAG_WIDTH-1:0] ins_tag_d;      // ✅ 时序寄存器用 _d
   reg [TAG_WIDTH-1:0] ins_tag_d;      // ❌ 禁止 _q
   ```

5. **纯打拍逻辑后缀带级数**：若时序寄存器是**无判断条件的纯打拍逻辑**（无条件延迟链，输入直接打拍输出），命名使用 **`_d1`、`_d2` …** 后缀，**数字代表打几拍**（延迟级数）：

   ```verilog
   // 2-cycle delay line: valid_d1 = 1拍延迟, valid_d2 = 2拍延迟
   always @(posedge clk or negedge rstn) begin
       if (!rstn) begin
           valid_d1 <= 0;
           valid_d2 <= 0;
       end
       else begin
           valid_d1 <= valid;
           valid_d2 <= valid_d1;
       end
   end
   ```

   有判断条件的寄存器（使能、数据通路寄存器等）不带数字，统一用 `_d`；同一信号沿延迟链逐级递增编号（`xxx_d1` → `xxx_d2`）。

---

## 9. 速查表

| # | 项目 | 要求 |
|---|------|------|
| 1 | 模块接口声明 | 端口按 方向 / 类型+位宽 / 信号名 三列对齐；端口组间空行+注释；parameter 的 `=` 对齐；末端口无逗号；**单文件统一竖线**：接口信号名、wire/reg 声明、实例化左括号同一列，且**列号 ≥ 40**、位宽 `]` 与信号名间隔 ≥ 4 空格（不足则整体右移，如 50） |
| 2 | wire/reg 声明 | 禁止声明行直接赋值；拆分为声明行 + `assign` 行（或 always 内赋值）；声明分组置前，赋值置后；信号名列落在文件级统一竖线 |
| 3 | begin...end | `begin` 与控制语句同行；`end` 独占一行并对齐；`else`/`else if` 独立成行；条件与语句体必须分行；单语句体可省 begin/end |
| 4 | 模块体缩进 | 除 parameter/端口列表外，模块体顶层构造一律从第 0 列开始；嵌套层级每级 4 空格缩进照常保留 |
| 5 | 模块实例化 | 逐行换行；`.port`/`.PARAM` 自第 5 列起；连接左括号落在文件级统一竖线；参数每行一个；末连接无逗号，`);` 独占一行 |
| 6 | 逻辑分区与就近组织 | 强关联信号组的声明/assign/always/实例化集中于同一分区相邻摆放；禁止声明-赋值-实例化远距离分布；全局/跨分区信号仍集中在顶部声明区 |
| 7 | 时序逻辑复位 | 异步复位同步释放：`always @(posedge clk or negedge rstn)` + 首分支 `if (!rstn)` 复位到常量；禁止无复位的寄存器 always 块；复位低电平有效，信号名以 `n` 后缀结尾（`rstn`/`rst_n`/`csr_rstn` 等，前缀不限）；存储器阵列例外（无复位） |
| 8 | 命名规范 | 变量名以小写字母开头（禁下划线/数字/大写开头）；大写仅限 parameter / localparam / 模拟信号名，且必须全大写；`` `define `` 宏全大写；时序寄存器用 `_d` 后缀（禁 `_q`），无判断条件的纯打拍寄存器用 `_d1`/`_d2`…（数字=打拍级数） |
| 0 | 基础 | 空格缩进（4 空格/级）；无行尾空白；文件末尾换行；Verilog-2001+；单文件单 module，文件名与模块名一致 |

---

## 10. 对既有代码的适用方式

- **新增文件**：必须完全遵守本规范。
- **既有文件**（`rtl/` 下的现存 RTL）：不强制一次性回改；建议在下次功能性修改该文件时顺带按本规范重排，且**重排单独提交**，不与功能变更混合在同一 commit 中。
- **§7 复位风格的既有偏差**：现存的无复位 pipeline 寄存器块（如 `tag_storage_ctrl_fsm.v`、`trie_lookup_engine.v` 中的部分时序块）补加复位属于**功能变更**而非纯重排，应随该模块的功能修改一并实施并验证，不得混入纯风格 commit。
- **§8 命名与 §1.9 竖线的既有偏差**：`_unused_falls`（matcher/select_lookahead_matcher.v）、`_unused_bkp`（trie/trie_lookup_engine.v）违反 §8.1，重命名为去掉前导下划线的形式即可（无逻辑影响）；多个文件的端口/声明/实例化竖线不统一（§1.9），随下次重排迁移到单竖线；竖线列号下限为 40——`free_list_mgr.v`（33）、`ripple_cell.v`（6）需整体右移至 ≥ 40。
- **§8.4/§8.5 时序寄存器后缀的既有偏差**：现存 RTL 全部使用 `_q` 后缀（如 `ins_tag_q`、`pred_ptr_q`、`ext_act_q`），须整体改名为 `_d`。该改名是**机械重命名、无逻辑变化**，但波及所有 `.v` 文件，应在专用 commit 中完成（可含纯重排）；改名时注意区分"真打拍链"与"带使能的寄存器"——历史上形如 `clr_d3` 的命名表达的是 CYC 节拍而非延迟级数，按 §8.5 语义逐个甄别后重命名。
