---

## 文件 2：`Fully_hardware_based_WFQ_architecture_for_high-speed_QoS_packet_scheduling.md`

# Fully Hardware Based WFQ Architecture for High-Speed QoS Packet Scheduling

**Authors:** Kieran McLaughlin (corresponding author, kieran.mclaughlin@ee.qub.ac.uk), Dwayne Burns, Ciaran Toal, Colm McKillen, Sakir Sezer

**Affiliation:** Queen's University Belfast, ECIT, Queen's Road, Queen's Island, Belfast BT3 9DT, UK

**Published in:** INTEGRATION, the VLSI journal 45 (2012) 99–109

**DOI:** 10.1016/j.vlsi.2011.01.001 | © 2011 Elsevier B.V. All rights reserved.

**Article history:** Received 25 May 2010; received in revised form 25 November 2010; accepted 14 January 2011; available online 28 January 2011.

**Keywords:** Fair queuing; WFQ; Packet scheduling; QoS; Traffic management; Shared buffer; FPGA

---

## Abstract

A full hardware implementation of a Weighted Fair Queuing (WFQ) packet scheduler is proposed. The circuit architecture presented has been implemented using Altera Stratix II FPGA technology, utilizing Reduced Latency DRAM (RLDRAM) II and Quad Data Rate (QDR) II SRAM memory components. The circuit can provide fine granularity Quality of Service (QoS) support at a line throughput rate of 12.8 Gb/s in its current implementation. The authors suggest that, due to the flexible and scalable modular circuit design approach used, the current circuit architecture can be targeted for a full ASIC implementation to deliver 50 Gb/s throughput. The circuit itself comprises three main components: a WFQ algorithm computation circuit, a tag/time-stamp sort and retrieval circuit, and a high throughput shared buffer. The circuit targets the support of emerging wireline and wireless network nodes that focus on Service Level Agreements (SLA's) and Quality of Experience.

---

## 1. Introduction

Emerging Internet services utilizing wireline and wireless platforms increasingly require greater bandwidth, lower end-to-end propagation delays and improved Quality of Service (QoS) guarantees. Applications such as Voice over Internet Protocol (VoIP), streaming audio, video and other real-time applications have specific bandwidth and propagation delay requirements. These demands create a bottleneck in the routers that form the infrastructure of the Internet, as they must handle ever increasing amounts of data.

Future demands for lower end-to-end propagation delays, greater bandwidth and dependable QoS guarantees cannot be suitably achieved with the ubiquitous best effort model, where packets from different types of traffic are treated without regard for priority needs. Real-time services require dependable performance bounds for delay, jitter and packet loss, which the best effort model cannot guarantee. However, voice, video and other streaming media represent a class of service that is extremely important for the future profitability of Internet Services Providers (ISPs).

Wireless operators in particular are experiencing an explosion in the bandwidth consumed by ever increasingly sophisticated mobile communication devices. Consequently, QoS for differentiated traffic classes and flows has become a major issue for emerging Long Term Evolution (LTE) wireless technology [1,2], where the provisioning of Service Level Agreements (SLA) and fine granularity QoS guarantees on a per-flow basis are vital for future operator business models, that plan to provide tiered SLAs to customers and guaranteed Quality of Experience for content providers [3].

Fairly arbitrating bandwidth and managing the QoS requirements between a large number of users, each potentially generating many different sessions and flows, is a challenging endeavor at the high throughput rates of modern networks. The processing power required to achieve this at the network nodes is immense, consequently software based solutions are incapable of supporting complex functionality. Therefore, offloading such processor intensive features to hardware is vital.

### 1.1. Outline of research

This paper presents the derivation of a Weighted Fair Queuing (WFQ) packet scheduler that has been fully implemented and verified as part of a commercial intellectual property core. It supports traffic management for QoS deployment at 12.8 Gb/s line-speeds, using FPGA technology, and combines a number of key research projects targeting WFQ algorithm processing handled entirely in hardware, WFQ associated tag sorting and lookup in custom accelerated hardware, and a scalable shared buffer memory capable of managing data payload storage and retrieval for multi-gigabit line-speeds. The circuit has been implemented using Altera's traffic management development board (Fig. 1), which utilizes Stratix II FPGAs, with access to a number of onboard resources such as RLDII and QDRII memory components.

> **Fig. 1.** Altera Traffic Manager Development Board, used to implement the WFQ scheduling traffic manager.

This work proves the feasibility of the circuit for deployment using more advanced FPGA technology or ASIC, targeting packet throughput rates of up to 50 Gb/s. The traffic manager is suitable for core and access deployment in traditional wireline applications, and also in future LTE wireless networks, where it can be used to enable support for SLA's and Quality of Experience.

**Key contributions:**

1. **WFQ computation circuit** — utilizes a highly pipelined and customized parallel processing architecture, enabling extremely fast finishing tag computation with a relatively small hardware cost. The embedded memory used was dimensioned to support up to 8000 sessions without external memory; it can support up to 64,000 different sessions without modification if sufficient embedded or external memory for session parameter storage can be accommodated. Further extension of the lookup table hierarchy permits the support of 8 million different sessions or individual IP flows.

2. **Finishing tag lookup table architecture** — key advantages over the previous state of the art: a fixed and predictable lookup time, and the ability to guarantee that the lowest tag value will always be found. Analysis of a range of viable alternatives (including standard software arrangements) shows the multi-bit tree based design offers the optimum solution in both speed and performance. The architecture is scalable in terms of number of tags, sessions and packets, delivering high performance with low latency. It can also be deployed for algorithms other than WFQ which require high-speed finishing tag sorting and lookup.

3. **High performance shared buffer architecture** — uses standard FPGA and RLDRAM technology to achieve throughput rates comparable with standard cell (ASIC) technology. Current dynamic RAM technology is optimized for cache based microprocessor systems that achieve maximum memory bandwidth access only in burst mode; utilizing DRAM technology for shared buffer design requires fine tuning of the access mode. The study shows operating a shared buffer architecture using FPGA technology is possible even beyond the 12.8 Gb/s achieved using RLDRAM II memory technology.

The overall performance of the WFQ circuit is limited by the technology available on the development board, particularly the memory bus between the FPGA and the RLDRAM II. In order to support a packet throughput rate of 12.8 Gb/s, the overall memory bandwidth required is 2N (25.6 Gb/s) and the overall system bandwidth at the control device (FPGA), excluding packet and flow descriptor memory access, is 4N, i.e. over 50 Gb/s for a 12.8 Gb/s shared buffer.

The remainder of the paper discusses the background of QoS and various scheduling approaches; derives the WFQ computation circuit, the tag sorting circuit and the shared packet buffer; and finally presents the FPGA prototype implementation. Further work discussed in the conclusion provides evidence that state of the art silicon technology can support packet buffering, and WFQ itself, at up to 50 Gb/s.

---

## 2. Background

### 2.1. Quality of service

Delivering QoS means guaranteeing given parameters within certain bounds for connections made over a network [4]. QoS can be applied differently to connections or users, as well as to different types of traffic and data flows. The parameters involved in QoS can be classified as **delay**, **jitter** and **packet loss**.

- **Delay** is inherently unpredictable under best-effort, except to say that if a network is heavily loaded, the amount of delay is likely to increase since packets can be held up in long queues at busy network nodes.
- **Jitter** occurs when packets in a data stream reach their destination with different time delays. For streaming services such as VoIP, video conferencing and video on demand, this means video and audio can be intermittent. Jitter compensation is achieved with large de-jitter buffers, which introduce additional end-to-end delays, dependent on the maximum jitter value.
- **Packet loss**: when a network is congested, buffers can become full and packets may be dropped as a result, causing delays and jitter as packets must be requested again and retransmitted.

The circuit presented in this paper provides guaranteed levels of QoS using packet scheduling. The term "scheduling" encompasses a number of policies on which decisions are made when processing packets arriving and departing from a router. At a router, a number of "sessions" (or "flows") exist—streams of packets moving between nodes connected on a network. A number of different scheduling techniques exist for QoS and traffic management. Their main objective is to treat different traffic classes or flows of packets with a variable degree of priority in order to provide performance guarantees for a range of different traffic types and profiles. Most techniques aim to emulate the ideal scheduling capabilities of **Generalized Processor Sharing (GPS)**, which is a fluid model, where packets are organized into logical queues with an infinitesimally small amount of data serviced from each non-empty queue in turn. This achieves fair allocation of bandwidth but is not practical since it does not treat packets as complete entities. It does however provide a theoretical standard against which the performance of practical scheduling policies is benchmarked.

Fig. 2 shows how each flow in GPS is allocated a weight proportional to the amount of the total available bandwidth they have been allocated. For example, flow D is allocated twice as much bandwidth as flow C. For any time interval, each flow will have been served equally according to the weights allocated to them. Because IP packets are different lengths means that in practice all flows cannot be served equally as intended, since the scheduler must finish serving each individual packet before it moves on to the next one.

> **Fig. 2.** Generalized Processor Sharing (GPS) model, where w = relative weight allocated to flow. (Flow A: w = 0.125; Flow B: w = 0.125; Flow C: w = 0.25; Flow D: w = 0.5)

Numerous methods have been devised to function as close as possible to GPS, without assuming packets are infinitesimally small, such as Weighted Round Robin (WRR) [5] and Deficit Round Robin (DRR) [6]. More advanced schemes such as Weighted Fair Queuing (WFQ) have also been developed [7], where a virtual time tracks simulated GPS, allowing a worst case end-to-end queuing delay to be provided for guaranteed service connections. These algorithms are all conventionally implemented in software in commercial routers.

### 2.2. Round Robin scheduling

Round robin is a time-share approach where a "quantum" of data is processed from each input in turn to achieve fairness. A "round" is complete when all connections have been serviced once. **WRR** allocates weight to flows in order to apportion priority. To calculate normalized weights, the average packet size must be known, which is impractical for IP connections, and with a large number of connections, or small weights, WRR can be unfair over long periods.

**DRR** processes variable size packets without knowing their mean size, serving each flow only when a "deficit counter" for each queue is greater than the size of the packet at its head. A variation of DRR called **Modified Deficit Round Robin (MDRR)** adds prioritization in an effort to provide a minimum delay for differentiated services. Cisco is known to have implemented MDRR in some routers, for example to allow VoIP to be prioritized. VoIP packets are identified using the Types of Service (TOS) bits in the packet header. MDRR gives flows identified as VoIP precedence over other packets, either by always serving these packets while letting all others wait, or by skewing the round robin so that a VoIP flow is visited more often than other flows.

The principal drawback for round robin approaches is that **bounded delays cannot be provided effectively**. Some research has shown this is possible for fixed packet sizes based on modifying a classic round robin approach [8]; the authors suggest the scheme could be extended to variable packet sizes by using a credit based system, however no analysis or implementation of this has been carried out thus far. Although round robin and its derivatives work well for protocols that use fixed packet sizes, such as Asynchronous Transfer Mode (ATM), they have proven to be unable to guarantee delay bounds for variable sized packets, and are unsuitable for providing full QoS for networks such as the Internet.

### 2.3. Fair queuing scheduling

A number of more advanced algorithms known as fair queuing scheduling act more fairly and more closely to GPS than round robin approaches. WFQ [7] and Packet-by-packet Generalized Processor Sharing (PGPS) [9] use a "virtual time" to track the progress of simulated GPS, allowing a worst case end-to-end queuing delay to be guaranteed for connections. These are effectively the same algorithm, developed independently, and were the first to become widely adopted in industry, for example by Cisco.

### 2.4. Weighted Fair Queuing

WFQ can be described as a rate based flow control strategy, where a traffic source is statistically characterized by rate, burstiness, etc. Worst case or average delays may also be specified, with the aim of providing guarantees on throughput and worst case delay. WFQ operates a simulation of GPS in parallel using a virtual time in order to decide which packet will be served next. This is determined as the next packet that would be served under GPS if no further packets were received after time t, assuming that the server becomes free at time t.

For each packet the WFQ simulation of a virtual time is used to allocate a **"start tag"** and also a **"finishing tag"**, which is the time the packet would leave the scheduler if it were operating GPS. Each packet is stored along with its designated finishing tag and when the scheduler output is free, the packet with the smallest finishing tag is transmitted. WFQ outperforms round robin approaches because it approximates GPS within one packet transmission time regardless of the arrival patterns and handles variable packet lengths in a more systematic approach.

### 2.5. Other fair queuing algorithms

- **Class-Based Weighted Fair Queuing (CBWFQ)** — a limited implementation of WFQ that acts on user defined classes of traffic, rather than on a per-flow basis. Implemented for example on Cisco's 2600, 3600 and 7200 routers, where it supports a maximum of 64 classes of traffic.
- **Frame-based Fair Queuing (FFQ)** and **Starting Potential-based Fair Queuing (SPFQ)** — both Rate Proportional Service (RPS) scheduling algorithms [10]. FFQ recalibrates periodically, where fairness depends on the frame size. In comparison, SPFQ recalibrates at the end of each packet transmission, which requires more state information to be stored, making it more complex.
- **Self Clocked Fair Queuing** [11] — derived from WFQ. Less complex but has inefficient latency tuning characteristics and can have a large delay bound.
- **Credit Based Fair Queuing (CBFQ)** [12] — less complex than WFQ but also less fair; similar in operation to DRR.
- **Worst Case Fair Weighted Fair Queuing (WF²Q)** [13] — more complex than WFQ but with better fairness. WFQ cannot fall behind GPS by more than one maximum size packet (the delay bound), but it can end up ahead of GPS. In WF²Q the algorithm is bounded by one maximum packet size behind or ahead of GPS, meaning its worst case fairness is better. However, it is more complex in terms of updating the virtual clock and, like WFQ, requires sorting finishing tags at the output.
- **WF²Q+** [14] — possesses the properties of WF²Q, but has a less complex procedure for updating the virtual clock. However, as well as sorting at the output (virtual finishing time) it also requires virtual starting times to be sorted to update the virtual clock, i.e. **two complex tag sorting operations per packet**.

### 2.6. Summary

For variable sized IP packets, it has been shown that fair queuing algorithms offer a number of advantages over alternative algorithms in terms of delivering QoS; such as guaranteeing minimum bandwidth, sharing excess bandwidth fairly and providing guaranteed delay bounds. Despite these clear advantages, a major reason often cited for using methods other than fair queuing is that it involves complex processes that must be achieved at line speeds, such as sorting packet finishing tags and updating a virtual clock [8,15–19]. However, the approach taken in this research has been to target the implementation of fair queuing by deriving novel high-speed circuits, rather than settle for alternatives that merely approximate the fairness properties provided by fair queuing.

Due to the line-speeds required for future Internet applications and services, this work has focused exclusively on a hardware implementation in order to gain a performance advantage over existing scheduling implementations, which are typically software based. A WFQ policy has been used to implement the packet scheduler. Although WFQ does not provide quite the same level of fairness as WF²Q, it is less complex to implement. In this case there is a trade-off balancing the complexity of the hardware design and the guaranteed worst case fairness. However by implementing the scheduler in hardware, this research shows the advanced QoS fairness guarantees enabled by fair queuing can be delivered without sacrificing the throughput performance achieved by less complex, less fair, techniques.

---

## 3. Decomposition of WFQ traffic scheduler

The design of the WFQ traffic scheduler has been decomposed into a number of separate parts, as illustrated in Fig. 3. The packets follow a path through the circuit from left to right. The packets enter the scheduler input and the required data such as traffic class, flow ID, etc. is parsed before the packet data itself is stored in the shared packet buffer. The WFQ calculation itself is carried out in the **WFQ tag computation circuit**, which among other functions produces a 'finishing tag' for each packet received. These tags are passed on to the **finishing tag sort/retrieve circuit**, which sorts and stores tags in order, from smallest to largest. A pointer to the location of the associated packet data payload in the shared packet buffer is stored along with the finishing tag values. When a packet is scheduled (according to the WFQ algorithm) to be transmitted at the output of the scheduler, the lowest finishing tag and associated shared buffer pointer are obtained from the tag storage memory. The packet server can then retrieve the correct packet payload from the buffer and it is transmitted.

> **Fig. 3.** WFQ packet scheduler architecture overview.
> 组成模块：Incoming Packets → WFQ Computation Circuit → Tag Sort/Retrieve Circuit ↔ Tag Storage Memory；Packet Buffer Write/Read Control ↔ Shared Packet Buffer → Scheduler Output。

### 3.1. WFQ computation circuit

This circuit in the packet scheduler is responsible for all calculations necessary to operate the WFQ algorithm. It also tracks the data associated with active session connections, which is necessary for the operation of the WFQ calculation. Packet information is received at the input along with a pointer to the location of the related packet payload in the shared buffer. At the output, finishing tags are passed to the tag sort/retrieve circuit along with the associated pointer.

To simulate GPS using WFQ, a virtual time measure, V(t), is used. The operation of the scheduler can be separated into two distinct parts, packet arrival and packet departure, each of which is defined as an event, where tⱼ represents the time at which the jth event occurs. The set of sessions that are busy in an interval (tⱼ₋₁, tⱼ) is fixed and denoted as Bⱼ. In WFQ, each session represents a virtual queue. V(t) is set to zero for all times when the server is idle, and φᵢ is the weight set for session i. For an interval τ with a constant set of backlogged flows within any busy period, V(t) increases using (1):

```
V(tⱼ₋₁ + τ) = V(tⱼ₋₁) + τ / Σᵢ∈Bⱼ φᵢ ,   τ ≤ tⱼ − tⱼ₋₁,  j = 2,3,...    (1)
```

Next(t) is the next point in real time at which the set of backlogged flows may change as a result of a packet departure, thus affecting the slope of V(t). Next(t) is calculated using (2), assuming that there are no further arrivals of packets in the interval (t, Next(t)). FMIN is the minimum value of finishing tag yet to depart the GPS simulation:

```
Next(t) = t + (FMIN − V(t)) · Σᵢ∈Bⱼ φᵢ                                    (2)
```

A start tag is calculated for each packet that arrives, using (3), and once this is set, the finishing tag can be computed using (4):

```
Sᵢᵏ = max{ Fᵢᵏ⁻¹ , V(aᵢᵏ) }                                               (3)

Fᵢᵏ = Sᵢᵏ + Lᵢᵏ / φᵢ                                                       (4)
```

where:
- `Sᵢᵏ` — start tag given to the kth packet in session i;
- `Fᵢᵏ` — finishing tag of the kth packet in session i;
- `V(aᵢᵏ)` — virtual time in GPS when the kth packet from session i arrives;
- `Lᵢᵏ` — length of the kth packet in session i;
- `φᵢ` — weight of session i.

Fig. 4 shows the modular circuit architecture developed to implement the WFQ algorithm. Three dual port memories are utilized, which are addressed based on each packet's flow ID values, where each flow is represented by a single virtual queue. For each session the memories store the **weight**, **previous finishing tag (Fᵢᵏ⁻¹)** and the **number of packets yet to leave the server (Count)**. The memories used are 16-bits wide, while the number of supported queues is determined by the size of memory available.

> **Fig. 4.** Finishing tag block level description.
> 输入：Flow ID、Packet Length；存储：φᵢ、Fᵢᵏ⁻¹、Count；输出：FTag & Flow_ID；核心：Finishing Tag Computation Block。

An initial version of the complete finishing tag computation circuit has been synthesized, targeting **130 nm ASIC technology**. The circuit operates with a clock period of **5.8 ns, or 173 MHz** [20]. It deploys 3 pairs of 8-kByte dual-port memory blocks, using 13-bit flow ID values. This enables the circuit to support up to **8000 different service classes (virtual queues)**, each with its own individual QoS parameters. The circuit combines a number of functional blocks, along with distributed memories in a fully pipelined architecture, to allow the data path to compute **one finishing tag per clock cycle**. The number of flows in the circuit is limited by the memory size to 8000 flows. However, 16-bit addressing is accommodated, therefore if additional memory is available, the same circuit can handle **64,000 independent flows**.

### 3.2. Finishing tag sort/retrieve circuit

This is a time critical component for most fair queuing algorithms and represents a key bottleneck, particularly for the software implementations common in industry. Although tags can be sorted using established software algorithms [21], no satisfactory design exists to facilitate the process effectively in hardware at high speed. For example, the classic van Emde Boas method is unsuitable for implementation in hardware [22]. A key research aim is to bridge the gap between the accuracy of software and the potential throughput achieved by hardware.

Most research in this field implements the tag sorting mechanism using queue/heap methods in software. These are generally limited to **O(log N)** performance. Various types of calendar queues have been implemented [23,24]; however, it has been shown that these are limited in size and scalability. A two dimensional calendar queue (TCQ) [25] claims **O(log log N)** performance, but it degrades the delay guarantees provided by the WFQ algorithm. The Leap Forward Virtual Clock (LFVC) algorithm has the same performance as TCQ but also similar drawbacks affecting the accuracy of the implementation of the scheduling algorithm [26].

**Stratified Round Robin (SRR)** is an approach suitable for hardware implementation that uses "finite universe priority queues" to sort packets among tens of classes [22]. However, as shown in Section 2, round robin is inherently less fair than fair queuing, and furthermore, in SRR the number of traffic classes is very limited. The **"binning" technique**, developed for a Credit Based Fair Queuing (CBFQ) hardware implementation [12], is also unsatisfactory because it aggregates values together in groups introducing inaccuracy.

A prime reason given for developing SRR was the bottleneck of sorting tags, which emphasizes that tag sorting is often seen as an obstacle against using fair queuing. The tag sorting circuit developed in this research overcomes this obstacle.

#### 3.2.1. Optimized solution for hardware

A comparison of the properties of a range of search and sort methods was performed [27]. The analysis included: calendar queue, Fibonacci heap, binomial heap, LFVC, binning (value aggregation), binary search, CAM, TCAM, tree and multi-bit tree. Consideration was made in terms of the number of memory accesses per operation, memory access time requirements, accuracy due to search granularity/aggregation of data, value insertion, value removal/deletion update times, worst case performance, and hardware timing constraints. A major factor limiting a number of potential solutions was that they could not deliver the smallest value from a set of tags within a **fixed and predictable time period**. This is vital for optimizing performance in hardware. The other modules in the scheduler operate with fixed pipelined timing strategies. If the tag sort/retrieve circuit operation is non-deterministic, integrating it into the broader scheduler circuit becomes complex, and importantly, the overall throughput will not be optimal and the advantages of using hardware would be reduced.

Results of the study show that a **multi-bit tree** offers a fixed guaranteed sort time, comparing favorably against existing standard software algorithms in this regard. The multi-bit tree does not compromise accuracy by aggregating data, as in some of the other hardware solutions previously described. Furthermore, the multi-bit tree is well suited for implementation using multiple distributed memories to enable high-speed parallel processing in hardware.

#### 3.2.2. Tag sort/retrieve circuit architecture

A custom tag sort/retrieve circuit based on a multi-bit tree has been derived where the **sorting and storage elements have been separated** such that they are independently scalable and configurable, allowing different parameters of memory size and search granularity to be realized. The circuit architecture consists of a number of distributed memory elements accessed by a set of custom designed logic circuits that enable data lookup, as illustrated in Fig. 5.

> **Fig. 5.** Finishing tag sort/retrieve circuit architecture.
> 数据流：New Tags In → Matching Circuitry → Multi-bit Lookup Tree → Translation Table → Tag Storage Memory → To Scheduler Output / To WFQ Tag Computation。

The full derivation and operation of the circuit architecture is available in [27]. A sorting mechanism and memory structure utilizing a multi-bit tree stores whether a finishing tag value is present in the tag storage memory. For incoming tags, a search for a matching tag value in the tree is used to place the new tag beside its closest match in the tag storage memory, a process which includes setting a tag marker in a translation table. Separating the search function from the data storage, via the translation table, allows the lookup function to be implemented very efficiently in hardware since memory pointers do not have to be accommodated directly alongside the circuitry used for the search.

The tag storage memory uses a **linked-list structure** to store the tag entries in order, which means that the smallest tag value, i.e. the tag to be serviced next, is always known and instantly accessible. It also enables tags to be deleted from the end of the list as they depart. This removes a processing bottleneck that exists with heaps and queues.

The initial architecture was developed and implemented with a **3 level multi-bit tree, handling 12-bit words**, where literals of 4-bits are represented in each level by 16-bit nodes. The first two levels of the tree are relatively small, 272-bits in total, so these are implemented using **registers**. The third level is 4 kbits and is implemented using **single port on-chip SRAM**. This relatively small amount of on-chip memory allows very fast access to the data needed to operate the search function. The size of memory, in bits, required for each level of the tree (level memory, LM) is:

```
LM = 2^(log₂(b)·l)          (5)
```

And it follows that the total memory required for the tree, M, can be expressed as:

```
M = Σᵢ₌₁ᵏ 2^(log₂(b)·i)     (6)
```

where `l` is the level number (level 1 is the tree root), `b` the branching factor, and `k` the total number of levels.

Therefore, using a multi-bit tree rather than a binary tree allows the search operation to be accelerated as well as requiring less memory.

At each level of the tree custom circuits are required to perform a matching function comparing the input literal with the existing node value. If an exact match is found it means a value in the tree already exists with this 4-bit literal at this level, consequently the search will continue in the next level. If a non-exact match occurs in any level, i.e. only a smaller value than that requested is present, then all subsequent levels return their maximum value.

A separate detailed investigation of custom matching circuit designs examined look ahead based circuits, including a simple ripple cell approach, a standard look-ahead circuit as well as block look-ahead, skip & look-ahead, and **select & look-ahead** circuits. All circuits are based on modified adder carry chain acceleration techniques. Of the five accelerated matching techniques, a **select & look-ahead approach was the fastest and most hardware efficient** option available. The 16-bit version has been used in the prototype circuit, which uses 4-bit literals; however the design is also sufficiently fast to allow the tree nodes to be implemented with 32 bits, accommodating 5-bit literals and 15-bit words. The translation table would expand to 32k entries as a result, and the granularity of search possible would be increased [28].

#### 3.2.3. Tag storage memory

A system of linked-lists is used to implement the tag storage memory. Each entry in the tag storage list stores a tag value and a pointer to the next link, which will be the next biggest tag value in the memory. The link at the head of the list is the smallest tag value. The list is implemented in this case using **FPGA block RAM** resources. The tag storage memory and the tree are independently scalable and configurable—the granularity or accuracy of sorting the tags depends on the tag sort/retrieve circuit, while the size (word width) and number of tags stored is decided by the size of RAM available for tag storage.

The translation table provides an essential bridge between the search tree and the tag storage memory allowing them to be separately scalable. The translation table records the physical memory address of each tag value in the linked list, where the position of the record in the table is addressed using the tag value itself.

Depending on the accuracy of the WFQ computation, tag values may be rounded off so that theoretically two or more tags of the same value can exist in the scheduler at one time; however, the sequential nature of the linked list allows a **first-come-first-served policy** to be applied when duplicate values exist. When adding a new tag value that already exists in the system, the translation table records only the most recent tag to have entered the linked list, while duplicate tags are inserted beside each other in the linked-list, and are served in the order received by the tag lookup circuit.

The tag storage memory requires **4 clock cycles (2 read and 2 write cycles)** to complete a full insertion cycle, while the tree and translation table require a total of 4 clock cycles to throughput one tag. This arrangement therefore allows the operation of these components to be optimally synchronized and efficiently pipelined. When implemented using UMC 130 nm standard cell technology, the circuit is capable of supporting sort/retrieve operations at a clock frequency of **143 MHz**, which equates to **35.8 million sort/retrieve operations per second, or 35.8 million packets per second** [28].

### 3.3. Shared packet buffer

The final component of the WFQ packet scheduler is the shared packet buffer. When a new packet enters the server, its data payload is sent to the packet buffer. The buffer produces a memory pointer for the location of the packet data, which is forwarded to the finishing tag lookup table. When a packet is served at the scheduler output, a pointer is retrieved from the lookup table and used to locate the correct packet payload in the buffer, which reads this data to the scheduler output.

Studies have identified the **shared buffer as the optimum buffering technique** [29], because it utilizes memory more efficiently and has a lower packet loss rate for a given buffer space, compared to strategies such as the input buffer [30] and output buffer [31]. Shared buffer architectures already exist for ATM switches [32] using 32 and 16-byte cells, but these cannot buffer variable sized packets as required in IP networks. However, recent work has shown that a shared buffer targeting variable size packets is possible using standard FPGA technology [33].

#### 3.3.1. Shared buffer implementation

For functions with high data capacity requirements such as the shared packet buffer, memory access is frequently a limiting factor when FPGAs are used. SRAM memories perform well in terms of latency but their high cost and low memory capacity make them impractical for high capacity buffering in network processing. DDRRAM II memory architectures have high memory capacities but are hindered by latency. Consequently, **RLDRAM II** memory has been used, which is a type of memory with a capacity similar to that of DDRAM II, but with a lower latency. It employs a double data rate I/O for increased bandwidth and an eight-bank architecture that decreases the probability of random access conflicts and is optimized for high-speed operation.

There are separate I/O (**SIO**) and common I/O (**CIO**) option modes:
- **SIO** has separate READ and WRITE ports to eliminate bus turnaround cycle (switching between read and write) and contention, thus achieving full bus utilization.
- **CIO** has a shared READ/WRITE port that requires additional cycles in order to switch the memory bus between read and write access. It is optimized for data streaming, where the near-term bus operation is either 100% READ or 100% WRITE. For the shared buffer implementation, the memory bandwidth must be fairly divided into a read and write access when the RLDRAM access operates in CIO mode. Switching the common I/O between read and write access costs an additional time, called **bus-turnaround-time**. Therefore, a no-operation (NOP) cycle-slot must be included.

The access latency to a specific memory bank is determined by the row-cycle times, and read or write latencies.

Previous work [34] has shown that CIO mode can be utilized within a shared buffer to support **12.8 Gb/s** throughput. This is scalable up to **20 Gb/s** if SIO mode is utilized, but at the penalty of higher hardware costs. The work focused on optimizing the memory bandwidth achievable for different payload sizes, assuming a minimum payload of 60-bytes with a 20-byte header. The packet buffer controller targeted the same Altera Stratix II speed grade −4 device used onboard the Altera Traffic Management board, which has been used for the overall WFQ scheduler implementation. The RLDRAM II required the controller to operate at **200 MHz**, which is easily attainable using Stratix II FPGA technology. The research showed a **TDM cadence of 4-2-4-2** was effective at optimizing bus turnaround times for optimum memory bandwidth at 200 MHz. The shared packet buffer used **6668 ALUTs (less than 8% of the device)**.

Fig. 6 illustrates the implemented architecture. The data for individual packets is divided between cells of size **128-bytes**. A linked-list is used to track the position of subsequent cells belonging to individual packets, which are distributed throughout the shared buffer memory.

> **Fig. 6.** Shared packet buffer architecture.
> 包含：Ingress/Egress Control、双时钟 FIFO、高低频时钟域、Packet Memory State Machine、Control Memory State Machine、RLDRAM II Interface、4 × Packet Memories + 1 × Control Memory。

The architecture consists of **five CIO RLDRAM II memory chips**: four are 8-Mbyte devices with 36-bit data width and one is a 16-Mbyte device with an 18-bit data width. The four 8-Mbyte devices store the packets and the single 16-Mbyte device stores a linked list (queue descriptors). The memory interface operates at a **200 MHz, high frequency domain**, while the shared buffer control circuit operates at **100 MHz, low frequency domain**. The dual data rate allows memory access at both the rising and falling edges of the clock. FPGAs are well suited to multiple clock domains, since they already have a number of clock trees built into the fabric of the device. Dual clock FIFOs have been implemented, enabling data-access synchronization between the two clock domains.

---

## 4. Full WFQ scheduler FPGA implementation and synthesis results

The full WFQ traffic management scheduler comprising the WFQ algorithm computation circuit, tag sort/retrieve circuit, and the shared packet buffer has been implemented using the **Altera Traffic Management development board**, which utilizes Stratix II FPGAs, and accesses onboard resources such as RLDII memory components for the shared buffer and QDRII memories for use with the control logic. In the implementation the **system clock operates at 100 MHz while the memories operate at 200 MHz**, as previously discussed in the description of the shared buffer.

> **Fig. 7.** Full WFQ packet scheduler architecture.
> Altera Stratix II FPGA 内部包含：traffic_generator、ingress_ctrl、ingress_fifo (1k×160, 40×M4K)、tag_computation (64k×14, 2×M-RAM)、tag_sorter (16×M4K)、translation_lut (16k×88, 3×M-RAM)、server、pm_ctrl、egress_ctrl、ctrl_mem_ctrl、ll_mem (2M×18)、ctrl_mem；外部存储：4×8M×36 RLDRAM II (pm)、16M×18 RLDRAM II (pmc)、QDRII SRAM。

The synthesized circuit is capable of supporting WFQ traffic scheduling at line-speeds of **12.8 Gb/s**, conservatively assuming an average packet size of 80-bytes. Table 1 shows the resource utilization following synthesis targeted at the Altera **EP2S130F1508C4** FPGA device.

> **Table 1. Post-layout synthesis results.**

| Resource | Used/Total |
|---|---|
| System clock | 100 MHz |
| Memory clocks | 200 MHz |
| ALUTs | 18,542 / 106,032 (**17%**) |
| Pins | 410 / 1127 (36%) |
| PLLs | 4 / 12 (33%) |
| M-RAMs | 5 / 6 (83%) |
| M4Ks | 68 / 609 (11%) |

Approximately 17% of the available logic resources are used for implementing the WFQ circuit, with sufficient logic resources remaining to implement different network processing functions, such as packet header processing, flow classification and management on a single device.

The overall system bandwidth at the control device (FPGA), including ingress/egress traffic, RLDRAM access bandwidth (packet storage) and QDRII access bandwidth (WFQ descriptors) is approximately **100 Gb/s**. This is at the upper limit of the I/O bandwidth capabilities of the FPGA device used for this prototype, which is the constraining factor for implementing extremely high-throughput WFQ circuits beyond 20 Gb/s.

### 4.1. Testing and verification

In order to verify the operation of the WFQ packet scheduler, two performance benchmark tests were carried out.

**Test 1 — Badly behaved flow:** The scheduler was tested by injecting traffic flows into the circuit and examining the output. Three flows A, B and C, were each allocated different weights, so that according to the WFQ algorithm they are guaranteed **60%, 30% and 10%**, respectively, of the available bandwidth.

With the scheduler disabled, the traffic flows were injected into the device and a backlog of traffic was allowed to build up. The flows were injected with a ratio of **60:30:40 (A:B:C)**, which means that flow C is generating more traffic than is allocated under the WFQ weights specified above—it is acting like a "badly behaved" flow.

When the scheduler was enabled, the results showed that each flow was consequently allocated the correct amount of bandwidth specified by the WFQ weights applied, i.e. 60%, 30% and 10%. Fig. 8 shows how the flows are allocated the correct bandwidth. Note how the packets from flow C, which is badly behaved, are only given 10% of the available bandwidth, while the packets from the other flows are given priority. Only when flows A and B are not sending traffic are the backlogged packets of flow C scheduled for service.

> **Fig. 8.** Packet by packet throughput behavior results when a badly behaved flow is processed through the WFQ packet scheduler. (注入线速比 60:30:40；权重 60/30/10；输出线速比 60:30:10)

> **Table 2. Throughput allocation experimental figures.**
> *（结果覆盖三条流均积压的时间段）*

| Flow | Incoming line rate | Bytes served | Served line rate |
|---|---|---|---|
| 1 | 46.15% | 20,985 | **59.97%** |
| 2 | 23.08% | 10,512 | **30.04%** |
| 3 | 30.77% | 3,497 | **9.99%** |

**Test 2 — OPNET 模型对比:** The second test involved creating a model of the operation of the ideal WFQ algorithm using OPNET to simulate the expected behavior. The expected behavior from this WFQ simulation could then be compared against the behaviorally implemented hardware. This allowed the validity of the hardware implementation to be examined in terms of fairness and throughput guarantee.

> **Fig. 9.** Throughput provided by ideal WFQ simulated in OPNET.（三条流吞吐曲线）
>
> **Fig. 10.** Throughput provided with hardware model simulated in OPNET.（三条流吞吐曲线）
>
> **Fig. 11.** Normalized measured traffic throughput of circuit over time.（相对于 12.8 Gb/s 归一化的实测吞吐率）

Figs. 9 and 10 show the throughput performance for the ideal WFQ model and the hardware model simulated in OPNET. These results show a **close correlation between the ideal model and the hardware design**. Furthermore, Fig. 11 shows actual traffic measured from the circuit using a traffic analyzer under the same test conditions. Analysis of the circuit's performance with test packet flows has also shown a **bandwidth allocation error tolerance of less than 0.1%**.

---

## 5. Conclusion

To the knowledge of the authors, the WFQ packet scheduler presented in this paper is **the first full hardware implementation of such an architecture to be published**. The proposed circuit architecture provides fine granularity QoS support for Internet traffic at multi-gigabit throughput rates. Both the granularity of QoS and the throughput rates supported are not achievable with previous state of the art systems. The circuit is therefore ideal for deployment with high bandwidth wireline and wireless technologies, such as LTE, where tiered services based on SLA's are emerging for users and content providers.

The fully functional **12.8 Gb/s** FPGA based prototype circuit demonstrates that complex packet scheduling algorithms can be implemented in hardware to achieve accurate QoS provision, while delivering low latency and high throughput performance. The flexible, modular design approach supports the scalability of the architecture to use standard cell ASIC technology, suitable for **50 Gb/s** line speeds.

- **WFQ computation circuit** — able to process at speeds exceeding the performance of typical industrial software based implementations. Support for such high numbers of sessions at the high throughput rates achieved is only possible using dedicated hardware. The presented implementation is dimensioned to support **64,000 sessions**. The number of supported sessions (or individual IP flows) can be further scaled well beyond one million by increasing the finishing tag lookup table hierarchy.

- **Finishing tag sort/retrieve circuit** — a high throughput circuit that can support tag (or time-stamp) sorting at multi-gigabit line-speeds. This is a key contribution to resolving the issue of a much referenced bottleneck typically encountered when implementing fair queuing algorithms [15–19]. The authors suggest that the circuit might also be used to support other fair queuing algorithms other than WFQ, such as WF²Q.

- **Shared packet buffer** — investigation has shown that by using RLDRAM II technology, with an optimized TDM cadence strategy, the buffer can support a throughput rate of 12.8 Gb/s for an average packet size of 80-bytes. Due to the performance constraints of the technology used, in particular the memory bandwidth constraints, it is the shared packet buffer that limits the performance of this implementation of the packet scheduler architecture.

In order to address this bottleneck, further work has already been completed that utilizes a new circuit architecture for a shared buffer memory implemented using **Altera Stratix III FPGA with DDR3 memory modules**. This circuit is suitable for supporting data throughput rates of up to **50 Gb/s** [35]. Consequently, the authors propose that the throughput performance of the WFQ computation and sort/retrieve circuits can equally be improved by utilizing the same advanced silicon and memory technologies, so that the complete packet scheduler circuit can fully support 50 Gb/s.

The high throughput and low latency of the system is achieved by means of parallel dedicated processing units to deal with computation of scheduling algorithms, virtual queue management, and the service of the packets in accordance with the scheduling policy. However, this improved performance does not come for free, and the obvious disadvantage is that the architecture increases the hardware cost and the amount of distributed memory necessary. From a hardware cost perspective, the use of replicated hardware logic for queue management and dedicated distributed memory to hold the virtual queue descriptors adds a significant cost in comparison to traditional software based architectures, or even low performance hardware based alternatives. Nevertheless, this is a very familiar trade-off for vendors in the network processor industry. Consequently, processes where high throughput performance is essential are commonly offloaded to hardware accelerators.

The proposed WFQ circuit architecture and the research work presented in this paper has demonstrated and proven that high-performance and highly accurate WFQ implementations can be achieved purely in hardware. Furthermore, the modular approach of the proposed architecture permits the scalability of the WFQ circuits beyond 50 Gb/s, using state of the art semiconductor and memory technologies, providing sustainable throughput performance for emerging QoS sensitive high-bandwidth Internet applications in the future.

---

## Acknowledgments

The authors would like to thank Altera Corporation for their financial and technical support. This work was also supported by the Engineering and Physical Sciences Research Council (EPSRC), under grant EP/E028640/1.

---