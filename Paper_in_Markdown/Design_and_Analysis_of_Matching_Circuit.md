下面是为你整理并解析的该篇论文完整 Markdown 格式内容，可直接保存为 `.md` 文件（如 `Design_and_Analysis_of_Matching_Circuit_Architectures_for_a_Closest_Match_Lookup.md`）：

---

# Design and Analysis of Matching Circuit Architectures for a Closest Match Lookup

**Authors:** Kieran McLaughlin¹, Friederich Kupzog², Holger Blume², Sakir Sezer¹, Tobias Noll², John McCanny¹<br>**Affiliations:**<br>¹ The Institute of Electronics, Communications and Information Technology at Queen's University Belfast (QUB)<br>² The Institute of Electrical Engineering and Computer Systems at RWTH Aachen University<br>**Published in:** Proceedings of the IEEE Advanced Industrial Conference on Telecommunications / AICT 2006, Guadeloupe, Feb. 2006, pp. 224–229<br>**ISBN / IEEE Catalog:** 1-4244-0054-6/06 / © 2006 IEEE

---

## Abstract

This paper investigates the implementation of a number of circuits used to perform a high speed closest value match lookup. The design is targeted particularly for use in a search trie, as used in various networking lookup applications, but can be applied to many other areas where such a match is required. A range of different designs have been considered and implemented on FPGA. A detailed description of the architectures investigated is followed by an analysis of the synthesis results.

---

## 1\. Introduction

The Internet is changing and moving towards interactive multimedia communications, with existing discrete services integrated onto a single platform. To enable this requires greater bandwidth, lower end-to-end propagation delays and improved Quality of Service (QoS) guarantees. Applications such as VoIP (Voice over Internet Protocol), streaming audio, video and other specialised applications have specific bandwidth and propagation delay requirements. Such demands create a bottleneck in the routers that form the infrastructure of the Internet as they must process ever increasing amounts of data.

Greater bandwidth requires faster transmission of packets which in turn requires faster search and lookup techniques for data associated with packets, paths and packet flows. In fact interactive services are usually based on small packets to reduce end to end delays. As a result the packet classification, lookup and scheduling speeds required increase even more than the bandwidth required.

It is difficult for the traditional software solutions currently used in routers to perform high-speed data retrieval as required for next generation QoS enabled networking. Future designs require hardware architectures that can deliver greater control over memory management and the number of accesses per lookup to slow off-chip memory.

This paper investigates the design and implementation of a hardware based closest match lookup circuit. A novel design based on a trie is proposed, which is composed of distributed memory blocks for parallel and pipelined sort and lookup. The latest FPGA technology has been chosen due to the embedded memory features, which is useful in particular for implementing the pipelined search trie.

---

## 2\. Related Work

Associative memory has been widely investigated for network processing and pattern, speech and image recognition. Most of these architectures were designed under application related constraints, such as the number of entries, cost and lookup performance. A number of existing associative memory implementations are available:

-   **Content Addressable Memories (CAMs):** These are "hit or miss" components. An entry is either present or not and they therefore have limited suitability for closest or non-exact match lookups, although a number of implementations have been examined. One common approach makes use of standard CAMs, which give either an exact match or no match. Different bits of the desired match are masked during a series of requests:
    
    -   At first, no masking bits are set.
        
    -   If there is no match, then one bit of the word is masked and requested again.
        
    -   The masking pattern is then altered, masking all combinations until a match is found.<br>Obviously this iterative masking process is time consuming, especially for wide data words. This approach is used in a parallel form in image coding, using Vector Quantization [1].
        
-   **Non-CAM Pipelined Cascaded Cells:** Other non-CAM approaches seek to avoid the high costs and insufficient performance of retrieving inexact matches using CAMs. A highly regular design is described in [2]. A basic cell containing a word of memory, a comparison unit and control logic is cascaded in a long pipeline. The requested word enters the pipeline as an input. Each cell compares the request with its own content and if it fits better than in the previous cell, the current cell will signal its own address to the next cell. This pipelined approach features a predictable, fixed response time and a high throughput rate. However, the latency is very high for large memories because the pipeline length is proportional to the memory size.
    
-   **Neural Networks:** Neural networks are an alternative for a best match lookup, in particular self-organising feature maps. VLSI implementations of neural networks are distributed processing systems with extensive connectivity. However, the fact that these connections have to be adaptable leads either to a reduced memory density or the use of non-standard VLSI fabrication techniques [2, 3, 4].
    

---

## 3\. Architecture

The distinct feature of the proposed closest match lookup architecture is the use of a sorter tree, or "trie", to implement an associative memory, which is able to return either an exact or next smallest match. The term "trie" is derived from *tree* and *retrieval*, proposed by Fredkin [5] as a specialised search tree that stores multiple strings. This original structure can be adapted to solve a range of numeric lookup problems, e.g. finding the entry with the smallest Hamming distance to a given value.

-   **Trie Depth & Branching Factor:** The number of levels in a trie determines the length of strings it can store. Its branching factor determines the number of literals of which the strings can consist.
    
-   **Pipelined Latency vs. Memory:** Since each level is usually accessed in one clock cycle, it is favourable to keep the number of levels low to reduce the latency of a pipelined implementation. Also, fewer levels will require less memory. To reduce tree depth, two or more bits can be grouped together into a single literal and stored in one trie level (multi-bit trie, branching factor $b > 2$).
    

> **Figure 1:** Multi-bit trie with values `001001`, `110101` and `110111`. (Branching factor = 4, literals: '00', '01', '10', '11', 3 levels, 6-bit strings).

### Data Representation and Retrieval Rule

Data is not stored by writing a value directly in memory, but by **setting flags (bits)** to indicate the presence of a value:

-   The final trie level consists of one flag (bit) for each possible value the trie can store ($4^3 = 64$ bits in Fig. 1).
    
-   To store a string, one bit is set in each level of the trie along the prefix path.
    
-   **Retrieval:** The result is assembled literal by literal while passing through tree levels. In each level, the desired search string literal is compared to the literal present in the trie:
    
    -   An exact or next smallest match is returned.
        
    -   If a non-exact match occurs (i.e. a smaller value than requested is returned), all subsequent levels return their **maximum value**.
        
    -   This ensures that if an exact match is absent, the overall string returned is the **closest value in the trie that is smaller than the desired search string** (e.g., closest match to `11 01 10` in Fig. 1 is `11 01 01`).
        

> **Figure 2:** Implementation of a trie with branching factor 16 (4-bit literals, 3 levels for 12-bit word, pipelined cuts, matcher per level).

The matcher is shared between nodes in a level since only one operation occurs at a time in each level. Therefore, each level consists of a memory and a "matcher". The structure can be pipelined and is scalable by either increasing the branching factor or adding more levels. Since memory access is the most time-dominant operation, the matcher delay must be matched as close to this time as possible to achieve optimum speed.

---

### 3.1 Matcher Architecture

The matcher requires a linear search to find the next smallest entry within a tree level. Due to its sequential nature, the matcher normally determines the critical delay.

The linear search is performed by ripple logic consisting of basic ripple elements:

-   A decoder injects a logic `'1'` into the ripple path at the position of the requested value.
    
-   This signal propagates through the ripple logic until it reaches a memory bit set to `'1'`.
    
-   The ripple process then stops, and the corresponding enable line is set to `'1'`.
    
-   Finally, the resulting value is encoded in binary format via an encoder.
    
-   **Critical Path:** Decoder $\rightarrow$Full length ripple path $\rightarrow$Output encoder.
    

> **Figure 3:** The basic ripple element with truth table.

#### Truth Table of the Basic Ripple Element

| $m_i$ | $d_i$ | $r_{i-1}$ | $r_i$ | $en_i$ |
| --- | --- | --- | --- | --- |
| 0   | 0   | 0   | 0   | 0   |
| 0   | 0   | 1   | 1   | 0   |
| 0   | 1   | 0   | 1   | 0   |
| 0   | 1   | 1   | \*  | \*  |
| 1   | 0   | 0   | 0   | 0   |
| 1   | 0   | 1   | 0   | 1   |
| 1   | 1   | 0   | 0   | 1   |
| 1   | 1   | 1   | \*  | \*  |

*\* don't care*

#### Logic Formulation (Analogy to Adder Carry Chains)

In an adder [6]: $$\\text{generate: } g\_i = a\_i \\cdot b\_i \\tag{1}$$$$\\text{propagate: } p\_i = a\_i \\oplus b\_i \\tag{2}$$$$\\text{carry: } c\_{i+1} = g\_i + p\_i \\cdot c\_i \\tag{3}$$

For the matcher ripple logic: $$\\text{generate: } g\_i = d\_i \\cdot \\overline{m\_i} \\tag{4}$$$$\\text{propagate: } p\_i = \\overline{m\_i} \\tag{5}$$$$\\text{ripple output: } r\_i = g\_i + p\_i \\cdot r\_{i-1} \\tag{6}$$$$\\text{enable signal: } en\_i = m\_i \\cdot (d\_i + r\_{i-1}) \\tag{7}$$

Most theorems developed to accelerate adder carry chains can be adapted to accelerate the matcher circuit.

---

### 3.2 Accelerated Matcher Architectures

#### 3.2.1 Look-Ahead Approach

Instead of sequential dependency on $r_{i-1}$, each ripple signal $r_i$is generated in parallel targeting $O(1)$delay: $$r\_i = g\_i + \\sum\_{\\mu=0}^{i-1} \\left( g\_\\mu \\prod\_{\\nu=\\mu+1}^i p\_\\nu \\right) + r\_{-1} \\prod\_{\\nu=0}^i p\_\\nu \\tag{8}$$

Although theoretically achievable in two logic levels (AND-OR), fan-in grows linearly with $i$. Gates must be split into tree structures, resulting in $O(\log i)$propagation delay and rapid logic area growth ($O(M^2)$), making pure look-ahead suitable only for short chains.

#### 3.2.2 Block Look-Ahead Approach

To reduce gate fan-in and area cost, hierarchy is introduced. Bits are grouped into $m$\-bit blocks generating Block Generate ($G$) and Block Propagate ($P$) signals: $$G = g\_{m-1} + \\sum\_{\\mu=0}^{m-2} \\left( g\_\\mu \\prod\_{\\nu=\\mu+1}^{m-1} p\_\\nu \\right) \\tag{9}$$$$P = \\prod\_{\\nu=0}^{m-1} p\_\\nu \\tag{10}$$

> **Figure 4:** 16-bit Block Look-Ahead structure (block size = 4 bits).

#### 3.2.3 Skip & Look-Ahead Approach

Adapting carry-skip adder principles [7], bits are grouped into blocks. If all propagate conditions in a block are true ($P = 1$), the ripple signal bypasses the block via a multiplexer/AND gate:

-   Only the starting block (where ripple initiates) and ending block (where ripple terminates) must be traversed through internal logic; intermediate blocks are bypassed.
    
-   Variable block sizing is used to balance path delays.
    

> **Figure 5:** Ripple Bypass using the propagate condition.<br>**Figure 6:** Variable block size Skip Matcher chain.

#### 3.2.4 Select & Look-Ahead Approach

Based on hybrid carry-select/look-ahead adder concepts [8], but significantly simplified for matchers:

-   **Key Simplification:** Unlike adders where multiple carries can generate at different stages, in a matcher once the ripple signal changes from `'1'` back to `'0'` (finding the first match), **it will never become** `'1'` **again**. All subsequent blocks can be ignored.
    
-   The ripple chain is divided into blocks that compute results simultaneously using internal look-ahead.
    
-   A central **"Result Control"** block coordinates the block enables ($r\_\text{in}$) in true parallel fashion.
    

> **Figure 7:** Select & Look-Ahead structure for 16-bit word length.

---

## 4\. Synthesis and Circuit Analysis

Circuits were modeled in VHDL and synthesized targeting **Altera Stratix II FPGA** technology with Quartus II.

-   **Bi-directional Matchers:** Implemented using dual matchers (one for next-smallest, one for next-highest) to avoid a "nil" return when no smaller value exists.
    

### 4.1 Matcher Results

#### Table 1: Propagation Delay $t_{pd}$[ns] for Matcher Architectures Across Word Lengths

| Implementation | 4-bit | 8-bit | 16-bit | 32-bit | 64-bit | 128-bit |
| --- | --- | --- | --- | --- | --- | --- |
| **Ripple Cells** | **2.3** | **3.9** | 6.2 | 8.8 | 14.2 | —   |
| **Skip & Look-Ahead** | —   | —   | 5.5 | 7.6 | 11.4 | —   |
| **Look-Ahead** | 2.4 | 4.0 | 5.8 | 7.7 | 9.5 | —   |
| **Block Look-Ahead** | 2.4 | —   | 5.8 | —   | 8.5 | —   |
| **Select & Look-Ahead** | 4.4 | 5.2 | **7.1\*** | **8.8\*** | **10.2** | —   |

*(Note: In Table 1 and Fig. 8/9 of the paper, optimal configurations are compared across ALUT cost vs delay).*

> **Figure 8:** Matcher delay comparison across word widths (0 to 128 bits).<br>**Figure 9:** Area-Time (AT) diagram (#ALUTs vs Delay) for 64-bit matchers showing the Pareto optimal front.

#### Key Findings from Synthesis:

1.  **Small words ($\le 8$ bits):** Classic Ripple Cells are best due to minimal logic levels and negligible routing overhead.
    
2.  **Look-Ahead scaling:** Area explodes at $\approx O(M^2)$. Block Look-Ahead reduces area by up to $3\times$at 64 bits with slightly better delay.
    
3.  **Best Trade-Off:** **Select & Look-Ahead** provides the most area-efficient solution among look-ahead schemes while maintaining near-minimal delay for word lengths $> 8$bits.
    
4.  **Pareto Front at 64 bits:** Ripple cells dominate at lowest area; Select & Look-Ahead dominates at medium area/high speed; Block Look-Ahead achieves the absolute lowest delay at high area cost.
    

---

### 4.2 Synthesis of the Lookup Trie

The multi-bit search trie was constructed using the **Select & Look-Ahead** matcher with pipelined stages. Three trie word widths were tested: **12-bit, 16-bit, and 20-bit**.

> **Figure 10:** Theoretical matcher delay vs actual maximum operating frequencies ($f_{\max}$) on FPGA.

| Configuration | Branching Factor | $f_{\max}$ | $f_{\max}$ |
| --- | --- | --- | --- |
| $\times$ | 8   | 192 MHz | 128 MHz |
| $\times$ | 16  | 192 MHz (5.2 ns) | **154 MHz** |
| $\times$ | 16  | 227 MHz | 214 MHz |

**Routing Delay Analysis:** The gap between theoretical matcher frequency and actual post-fit frequency is caused by placement around FPGA embedded memory:

-   Trie memory uses Altera Stratix II **M4K blocks** centrally located on the die.
    
-   Matcher logic is placed surrounding these memory blocks; as branching factor and level count increase, interconnect routing distance to the central M4K blocks increases propagation delay.
    

---

## 5\. Conclusions

This paper presents the architecture and implementation of a closest match lookup circuit based on a search trie for network processing and IP packet scheduling:

-   **Core Bottleneck:** The matching circuit within each trie level determines the critical path.
    
-   **Circuit Acceleration:** Carry chain acceleration techniques (Ripple, Look-Ahead, Block Look-Ahead, Skip, and Select & Look-Ahead) were adapted to the single-match nature of associative matchers.
    
-   **Optimal Choice:** For word widths $> 8$bits, the **Select & Look-Ahead** architecture provides the optimum area-delay efficiency due to simplification from the monotonic ripple property.
    
-   **Packet Scheduling Performance:** Targeting a 16-bit word length ($4 \times 4$\-bit branching factor), the design achieves **154 MHz** on standard Stratix II FPGA technology, enabling retrieval of **up to 40 million IP packets per second** at line speeds.
    

---

## References

1.  S. Panchanathan, M. Goldberg, "A Content-Addressable Memory Architecture for Image Coding Using Vector Quantization," *IEEE Transactions on Signal Processing*, Sept. 1991, pp. 2066–2078.
    
2.  L. T. Clark, R. O. Grondin, "A Pipelined Associative Memory Implementation in VLSI," *IEEE Journal of Solid-State Circuits*, 1989.
    
3.  T. Kohonen, *Self-Organization and Associative Memory*, Springer-Verlag, 1984.
    
4.  H. P. Graf, P. d. Vegvar, "A CMOS Associative Memory Chip Based on Neural Networks," *ISSCC 87*, Feb. 1987, pp. 304–305, 437.
    
5.  E. Fredkin, "Trie Memory," *Communications of the ACM*, vol. 3, no. 9, pp. 490–499, Sept. 1960.
    
6.  B. Parhami, *Computer Arithmetic: Algorithms and Hardware Designs*, Oxford University Press, 2000.
    
7.  M. J. Schulte, K. Chirca, et al., "A Low Power Carry Skip Adder with Fast Saturation," in *Proc. IEEE International Conference ASAP '04*, 2004, pp. 269–279.
    
8.  Y. Wang, C. Pai, X. Song, "The Design of Hybrid Carry-Lookahead/Carry-Select Adders," *IEEE Transactions on Circuits and Systems*, vol. 40, no. 1, 2002.
    
9.  R. K. Brayton, R. Spence, *Sensitivity and Optimization*, Elsevier, Amsterdam, 1980.