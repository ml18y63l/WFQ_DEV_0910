---

## 文件 1：`A_Scalable_Packet_Sorting_Circuit_for_High_Speed_WFQ_Packet_Scheduling.md`

# A Scalable Packet Sorting Circuit for High-Speed WFQ Packet Scheduling

**Authors:** K. McLaughlin, S. Sezer, H. Blume, X. Yang, F. Kupzog, and T. Noll

**Published in:** IEEE TRANSACTIONS ON VERY LARGE SCALE INTEGRATION (VLSI) SYSTEMS, VOL. 16, NO. 7, JULY 2008, pp. 781–791

**DOI:** 10.1109/TVLSI.2008.2000323

**Manuscript:** Received April 1, 2007; revised July 3, 2007. Supported by Invest Northern Ireland and the Department for Employment and Learning. Protected by Patent No. 0524845.

---

## Abstract

A novel implementation of a tag sorting circuit for a weighted fair queueing (WFQ) enabled Internet Protocol (IP) packet scheduler is presented. The design consists of a search tree, matching circuitry, and a custom memory layout. It is implemented using 130-nm silicon technology and supports quality of service (QoS) on networks at line speeds of 40 Gb/s, enabling next generation IP services to be deployed.

**Index Terms**—Internet packet scheduling, lookup, quality of service (QoS), time-stamp sorting, traffic management, weighted fair queueing (WFQ).

---

## I. Introduction

The Internet was the defining technology at the beginning of the 21st century. It has become the dominant medium for global communications, information, business, and entertainment. In the near future streaming services, such as video on demand, high definition television, voice over Internet Protocol (VoIP), and 3-D multimedia, etc., will rapidly take off. To deliver this next generation of applications requires a new generation of Internet routers that allow quality of service (QoS) to be delivered via the Internet.

Most current solutions aimed at providing QoS are based on software implemented on a network processor with multiple processor cores, but despite these configurations, software solutions are unable to keep up with the increasing bandwidth of the Internet, which doubles approximately every 12 months. In addition, streaming and real-time content associated with VoIP and IPTV introduces further constraints by reducing the packet size and setting rigid delay requirements. Despite the shortcomings of software, a comprehensive study investigating a full hardware implementation of fair queueing for IP traffic management has not yet been carried out—this research targets this specific application in order to overcome the processing limitations for next generation QoS supporting Internet routers.

This paper presents a novel tag sort/retrieve circuit, designed for an IP packet scheduler that deploys a weighted fair queueing (WFQ) scheduling policy, which is fully implemented in hardware. WFQ is one of a family of fair queueing algorithms the circuit can support in hardware [1]. WFQ can be described as a rate-based flow control strategy, where a traffic source is statistically characterized by rate, burstiness, etc. There may also be a QoS requirement such that worst case or average delays are specified, with the aim of providing guarantees on throughput and worst case delay. The novel contribution to this field of research is the high performance and low latency of the sort/retrieve circuit, which utilizes distributed memories to achieve parallel and pipelined processing that enables high speed tag retrieval in a guaranteed fixed time. The circuit is capable of supporting guaranteed QoS for future real-time services via a highly scalable implementation of WFQ packet scheduling. The circuit has been implemented using 130-nm silicon technology and supports line speeds of 40 Gb/s, which is an order of magnitude greater than emerging industry standards.

The rest of this paper is laid out as follows. The Introduction continues to discuss the need for QoS and how it can be enabled by deploying packet scheduling. A hardware-based WFQ scheduler architecture that has been derived is introduced and the need for effective finishing tag retrieval is explained. An analysis of theoretical models for searching and sorting tags is then carried out, followed by a performance analysis of practical implementation options. The final circuit architecture is then derived, which comprises a search tree, matching circuitry, tag storage memory, and a translation table. The full circuit architecture is then implemented on silicon and the results are presented.

### A. Delivering QoS

The current best-effort model that the Internet operates does not provide bandwidth or real-time guarantees, however, fair queueing scheduling does allow such guarantees to be delivered. The motivation behind this research is to derive hardware capable of supporting finishing tag sorting and retrieval for fair queueing scheduling. Fair queueing packet scheduling allows QoS to be guaranteed to specific packet flows in terms of propagation delay and the allocation of available bandwidth.

Providing QoS is vital for future streaming applications because they require a high level of guaranteed bandwidth in order to operate reliably and with customer satisfaction. Additionally, end-to-end delays for such packet flows must also be kept within certain limits if, for example, a conversation or other interaction is to be practical. At present QoS is only met by underutilizing network resources, this is inefficient and is not sustainable as user demand increases. Implementing QoS at the core and edge of the network using fair queueing scheduling allows service providers to deliver next generation services both effectively and efficiently.

### B. Router Design and Packet Scheduling

A number of scheduling techniques deal with the issue of QoS and traffic management. Most aim to emulate the ideal scheduling capabilities of generalized processor sharing (GPS), which is a fluid model, where packets are organized into logical queues with an infinitesimally small amount of data serviced from each non-empty queue in turn. This achieves fair allocation of bandwidth but is not practical since packets are not transmitted as complete entities. It does, however, provide a theoretical standard against which the performance of practical scheduling policies can be assessed.

Methods such as weighted round robin (WRR) [2] and deficit round robin (DRR) [3] were developed to offer a level of QoS. WRR is the simplest, where weights are allocated to different flows in order to apportion priority. However, WRR requires the average packet size to be known so that normalized weights can be calculated. DRR is able to process variable size packets without knowing their mean size. Extensions of the DRR approach have also been implemented. Class-based queueing (CBQ) [4] adopts a hierarchical approach to DRR. A further derivation of DRR called modified deficit round robin (MDRR) adds prioritization to try to provide a minimum delay for differentiated services. Cisco have implemented MDRR to allow VoIP to be prioritized. The principal drawback for a typical round robin approach is that it cannot provide for effective bounded delays.

Although round robin and its derivatives work well for fixed-sized packets, they have thus far proven to be unable to guarantee delay bounds for variable sized packets. Therefore, they are unsuitable for providing full QoS for networks such as the Internet. A number of more advanced algorithms known as fair queueing scheduling have been developed which act more closely to GPS. WFQ [1], which is discussed more fully in Section II, uses a "virtual time" to track the progress of simulated GPS and allocates a finishing time to all packets indicating when they are to be serviced. This allows a worst case end-to-end queueing delay to be guaranteed for all connections. WFQ outperforms round robin because it approximates GPS within one packet transmission time regardless of the arrival patterns.

A number of fair queueing-based derivatives have also been developed, which vary in terms of ease of implementation and performance parameters, although all are based on a system of allocating time stamps to packets. Worst case fair weighted fair queueing (WF²Q) is more complex than WFQ but has better worst case fairness [5]. The drawbacks are that it is complex in terms of both updating the virtual clock and, like WFQ, sorting finishing tags at the output. Another proposal called WF²Q+ possesses all the properties of WF²Q, but has a less complex procedure for updating the virtual clock [6]. The disadvantage with WF²Q+, however, is that it requires two sort operations per packet.

It is clear that the best choice for delivering QoS on the IP network is fair queueing. Although the scheduler architecture that is now presented uses WFQ, it is important to stress that the tag sorting architecture that has been derived can operate with any of the family of fair queueing algorithms that requires finishing tag timestamps to be sorted.

---

## II. Scheduler Architecture

A scheduler has been developed to enable sophisticated traffic management policies to be deployed on the Internet, including the delivery of specifiable levels of QoS for individual connections. The architecture is comprised of three main components: a WFQ tag computation circuit [8], a packet buffer [9], and a tag sort/retrieve circuit, highlighted in Fig. 1, which is the focus of this paper. The modular design approach allows each separate entity within the scheduler to be designed and configured independently. It also allows the system to be extremely scalable and flexible. For instance, any fair queueing based algorithm can be inserted into the architecture in place of the WFQ calculation circuit, e.g., WF²Q+. The scheduler operates by generating and processing "finishing tags" for each packet that it receives. The tags are time stamps that tell the system when each associated packet should be serviced in relation to all other packets in the scheduler.

> **Fig. 1.** WFQ scheduler architecture fully implemented in hardware.

When a packet enters the scheduler on the left of Fig. 1 the WFQ tag computation circuit generates a tag for that packet. The packet is stored in the shared buffer memory and the associated tag is sent to the tag sort/retrieve circuit. Here, all tags in the system are stored in order of value. When a packet leaves the scheduler, the lowest tag value is read from the sort/retrieve circuit and a pointer stored along with it indicates the location of the associated packet in the packet buffer. This means the packets are served in the correct sequence required by the WFQ policy.

### A. Fair Queuing and WFQ Tag Computation

There are a number of algorithms that aim to emulate the ideal scheduling capabilities of GPS in order to guarantee QoS parameters for different connections. In GPS, packets are organized into logical queues where an infinitesimally small amount of data is serviced from each non-empty queue in turn. This achieves a fair allocation of bandwidth but is not practical because it requires packets to be transmitted as incomplete entities.

Numerous algorithms have been developed to perform as close to GPS as possible, while retaining packet integrity. WFQ [1] uses a "virtual time" to track the progress of simulated GPS, allowing a worst case end-to-end queueing delay to be guaranteed for connections. Several other schemes have been developed such as fair weighted fair queueing (WF²Q), which is fairer than WFQ but is also more complex [5] and frame-based fair queueing (FBFQ), which is less complex than WFQ, but is almost as fair [7].

The operation of the WFQ algorithm involves a number of calculations. One in particular is especially relevant to the tag sort/retrieve operation:

```
Next(t) = t + (FMIN − V(t)) · Σ φᵢ (1)
```

where:
- `Next(t)` — time of next scheduled departure;
- `V(t)` — virtual time;
- `FMIN` — minimum time stamp;
- `t` — time;
- `i` — connection number;
- `Bⱼ` — set of busy sessions;
- `φᵢ` — weight of i-th session.

`Next(t)` in (1) is a point in real time related to the departure of the next tag in the scheduler [8]. It is used in the WFQ algorithm to calculate future virtual time `V(t)` values and, among other values, is dependant on `FMIN` which is the minimum time stamp value yet to leave the system, i.e., the smallest tag yet to be served in the tag sort/retrieve circuit. This highlights how the tag sort/retrieve operation is integral to the operation of the entire scheduler architecture and has an impact on its performance from input to output. Compared to the scheduling algorithms themselves, there has been little work focusing on this important issue in the research community and no satisfactory solution is currently available.

### B. Tag Sort/Retrieve Circuit

This is a critical operation for fair queueing scheduling. The finishing tag lookup must be possible at line speed to be effective. This represents a bottleneck, especially for software. In industry, fair queueing algorithms are normally implemented in software and while the specific operation of sorting tags can be achieved using established software algorithms [10], until now no satisfactory circuit design has existed to facilitate the process effectively in hardware. It should be noted that the van Emde Boas method is unsuitable for implementation in hardware [11]. The "binning" technique, developed for a credit-based fair queueing (CBFQ) hardware implementation [12], has been suggested as a solution, however, this method is unsatisfactory because it aggregates values together in groups and is inherently inaccurate.

Other possible solutions based on traditional associative memory arrangements also fall short of the performance required. The primary reason for this is that techniques such as hashing and content addressable memories (CAMs) cannot deliver the smallest value from a set within a fixed and predictable time period. The architecture developed can achieve this, which will be discussed in Section II-C.

Most work in this field has based the tag sorting mechanism on queue/heap methods. These are generally limited to O(log N) performance, which is slower than the multi-bit tree design presented. Various types of calendar queues have been implemented [14], [15], however, it has been shown that these are limited in their size and scalability. A 2-D calendar queue (TCQ) [16] claims O(log log N) performance [equivalent to O(log₂ log₂ N)], however, it produces a degradation of the delay guarantees provided by the WFQ algorithm. It also cannot be implemented as fast as the multi-bit tree presented. The LFVC algorithm has the same performance as TCQ but also similar drawbacks relating to the level of QoS delivered [17].

A recent development is stratified round robin (SRR), which uses "finite universe priority queues" to sort packets among tens of classes [11]. However, as previously stated, round robin is inherently less fair than fair queueing. The number of traffic classes is also greatly limited compared to the architecture that is presented as part of this paper. A primary reason given for developing SRR was the bottleneck of sorting tags in fair queueing.

### C. Search and Sort Models

The key aim was to produce an associative memory configuration capable of storing all the finishing tags in the scheduler and returning the smallest tag within a guaranteed fixed time. A fixed time is important because the operation of the other modules in the scheduler (see Fig. 1) depend on synchronizing around a fixed time. There are two functions in an associative memory: data storage and a lookup function to enable access to the data. There are two fundamental options for the tag lookup memory architecture:

1. Sort the tags as they arrive and then access the smallest tag value as required.
2. Store tags as they arrive and search through the memory to find the smallest tag when required.

These will be referred to as the "sort" and "search" models respectively and in this section searching or sorting will generically be referred to as a "lookup." Both models are illustrated in Fig. 2.

> **Fig. 2.** Sort and search model concepts.

The models can be assessed in terms of the time allocated to each function and how the time available between data entry and data request is managed:

- `T(l)` — lookup time;
- `T(s)` — time data is stored in memory;
- `T(r)` — time taken for read process;
- `T(w)` — time taken for write process.

The time that data is stored in the memory `T(s)` is variable and depends on the value allocated to a tag by the scheduling policy. It can, therefore, be considered an arbitrary value for the purposes of comparing models. The important factors to consider are the lookup time, which is variable, and the read and write times, which can be assumed to be constant for this investigation. The central point to emphasize is that the sort model allows the lookup function to be performed at the input of the data flow, compared to the search model where it is performed at the output.

The sorting model is preferable because it allows the service of the smallest tag to be separated from the lookup operation. This separation means that the service of the tags depends only on the time taken to access the tag storage memory `T(r)`, which is both fixed and faster than performing a lookup `T(l)`. For the sort operation only the average time taken to complete a lookup for each tag is important, because `T(s)` effectively acts as a buffer between the fixed and variable times of `T(l)` and `T(r)`. This is unlike the search model, where the time taken to service the smallest tag will depend on the performance of the search operation. The only guarantee that can be given for the length of time this takes is the worst case performance of the search, `T(l_max)`, which is almost certain to be longer than `T(r)` in the sort model.

### D. Lookup Performance

A comparison of the operational complexities for various options is shown in Table I along with information on which lookup model they conform to. The first four methods are standard software implementations and the remaining five are all hardware based.

> **TABLE I. Comparing Lookup Methods Available**

| Method | Model | Complexity (worst case) |
|---|---|---|
| Calendar queue | Search | O(N) |
| Fibonacci heap | Search | O(log N) |
| Binomial heap | Search | O(log N) |
| LFVC | Search | O(log log N) |
| Binning (aggregation) | Search | O(N) — inaccurate |
| Binary search / CAM | Search | O(N) |
| TCAM | Search | O(W) |
| Tree | Sort | O(W) |
| Multi-bit tree | Sort | O(W / log₂ b) |

In terms of speed of operation, the software speed is based on complexity of algorithm and for hardware the number of accesses to memory has been used. In each case, the slowest limiting factors have been used, i.e., worst case time for finding the minimum values, inserting new values, backup search paths, etc. Since the circuit must operate over a fixed time to fit within the overall scheduler architecture, the worst case results are necessary. Note that the performance for any implementation operating under the search model can only be guaranteed to a worst case scenario. In addition, note that using any other measure of performance would also be invalid because a search that is longer than anticipated would mean tags leaving the circuit later than scheduled by the fair queueing algorithm. This is not acceptable for a reliable scheduling policy.

For the hardware methods, the worst case number of memory accesses required per lookup have been calculated as follows. The number of accesses required for the binning method is limited only by the number of bins, which equals the total range divided by the span of an individual bin. A search in a binary CAM must use an iterative technique based on incrementing a search by one value at a time, which is very slow. A TCAM can use a bit-wise iterative search using masked bits and a tree can also use a bitwise search, which reduces the worst case maximum search to a linear relationship with the word width. A multi-bit tree further reduces this by the branching factor by analyzing more than one bit in parallel. It can be seen that performing lookups using the tree can be achieved with the lowest complexity compared to all the other options. Having previously established the sort model as the preferred option, it now becomes clear that the multi-bit tree is the best option available because of its operating speed and conformity to the sort model. The tree acts as a sort function and the linked list acts as the storage memory.

The most practical of the remaining options are binary CAM, TCAM, and the binning technique, which operate using the search model. The table shows that for the software models (except LFVC), the binning technique and the CAMs, the performance is in direct proportion to the number of tags being stored. Only the TCAM and tree implementations have lookup times proportional to the widths of the tags, which is an exponential reduction. Additionally, the tree implementation lookup time is also inversely proportional to the branching factor used in the tree, which further reduces the search time (`b = 16` in the implementation presented).

The option of a hash solution has not been included for comparison. The variables associated with such an implementation include the hash function itself, the size of table compared to the number of tags it must store, collision resolution and an iterative policy to find the smallest value. For hardware, it would be particularly difficult to calculate worst case performance bounds for a general implementation. However, taking into account that the nature of the iterative search required would be similar to that of a binary CAM and that collision resolution would be required, it is likely that the worst case performance would be worse than O(N).

Table I shows that the speed performance of the multi-bit tree-based architecture is better than the alternatives. In addition, it also conforms to the sort model as previously outlined; consequently, the service of the smallest tag is dependant only on the time taken to access the tag storage memory. It also compares favorably against existing standard approaches where the software algorithm will require several accesses to memory during operation. The multi-bit tree is well suited for implementation using multiple distributed memories to enable high-speed parallel processing in hardware. The following section shows the derivation of the tag retrieval circuit based on the multi-bit tree.

---

## III. Circuit Architecture

The key aim was to produce an associative memory configuration that can return the smallest available finishing tag within a guaranteed fixed time in hardware at line speeds. It was also desired that the design can support any fair queueing algorithm that generates tags or time stamps. For the scheduler developed in Fig. 1, it is required that all the tag values be stored in the tag storage memory in sorted order. This enables the lowest value to be readily accessible by the packet buffer read control at all times and also be available for the calculation outlined in (1). A sorting mechanism and memory structure have been developed that allow incoming tags to be inserted into the tag storage memory in the correct order relative to all other tags in the memory.

A custom implementation has been derived where the search and memory elements of the design have been separated so that they can be independently scalable and configurable, allowing different parameters of memory size and search granularity to be realized. The circuit architecture consists of a number of distributed memory elements accessed by a set of custom designed logic circuits that enable data lookup.

The design uses linked-list structures to organize the entries in the tag storage memory. This component is an integral part of the overall sorting procedure, since how the tags are stored is inexorably linked to the processes used to sort them. It is also important that the process of adding and removing tag values from this memory does not become a bottleneck in the data flow. The linked list configuration allows the tags to be stored in order of value, which means that the smallest tag value, i.e., the tag to be serviced next, is always known. This allows instant access to successive packets at the output and also enables tags to be deleted from the end of the list as they depart, which removes another potential bottleneck procedure that can be problematic in software, where heaps or queues are used.

New tags are inserted into the sorted list by using a lookup tree (or trie specifically) in conjunction with a translation table. A multi-bit tree is used to store whether a value is already present in the tag storage memory by storing a tag marker. This information is used to place the new tag beside its closest match in the linked list. For values that are present, the translation table indexes the position of each entry and provides a connection between entries in the tree and the linked list. Separating the search function from the data storage allows the lookup function to be implemented very efficiently in hardware.

The architecture is treated as three separate entities that are all part of one data flow as shown in Fig. 3. The first circuit is the tree that performs the lookup function; the second part is the translation table, which connects the tree to the third part, the tag storage memory. Additionally, custom designed circuitry is used to perform the closest match operations in the nodes of the tree.

> **Fig. 3.** Tag sort/retrieve circuit and tag storage architecture.

### A. Search Tree

The architecture was developed and implemented with standard cell logic and uses a tree with three levels, handling 12-bit words. This means literals of 4 bits are represented in each level by 16-bit nodes. The branching factor in each level is therefore 16, since each node has 16 child nodes. Since the tree has three levels, three identical matching circuits are required to perform a matching function at each level. The tag storage memory requires four clock cycles to complete a read/write cycle (see Fig. 9) and together the three level tree and translation table require four clock cycles to throughput one tag, this arrangement allows the operations of the separate components to be synchronized most efficiently. The width of the nodes could also be expanded to 32 bits to enable 15-bit words. This would also require the added expense of a larger translation table with 32-k entries. This would increase the granularity of search possible and there is no practical reason why this could not be done despite the additional area cost. Another option available is to use node widths that are not equal in each level, this option is discussed further in [13]. The main reason for not using this option is that the total search time will be most affected by the search time needed for the widest node. If all nodes are equal width, all will execute in equal time.

The tree records all the tag values already present in the system by storing a tag marker. When adding a new tag to the system, the tree is used to find the closest existing tag marker in the tree and hence the closest existing tag in the system. To facilitate this search, custom matching circuitry has been developed to operate on the nodes of the tree. Fig. 4 shows the operation of a very simple multi-bit tree that stores the values 001001, 110101, and 110111.

> **Fig. 4.** Simple multi-bit tree search.

In each level the desired literal is compared to the literal present in the tree and an exact or next smallest match is returned. The example uses 6-bit values with three 2-bit literals shown. If a non-exact match occurs in any level, i.e., a smaller value than requested, all subsequent levels return their maximum value. This process first of all finds a subset of values smaller than the desired value and secondly finds the largest value out of this subset, i.e., the value closest to the desired value. Consider an example where a new tag has arrived with a value of 110110, which must now be sorted and stored:

1. The search in the root level at the top of the tree will look for a "1" or "0" in the very right hand position of the node related to the literal "11." The memory bit "1" here indicates that this literal is present, so the search continues to the child node below it.
2. In this node, the "01" position is checked and again a "1" is found indicating that a tag marker beginning with "1101" is already in the memory.
3. In this node in the third level, the search will return the literal "01." This is because there is a "0" in the "10" position, so the matching circuit instead looks for the literal with the next smallest value after "10."

The final result is that the tree returns a closest match of "110101" for the incoming tag "110110." This value will then pass to the translation table to be used in the next stage. The final part of the process is writing the new tag marker into the tree. The only node that requires an update is the node in Step 3), where the value "0111" will be written to indicate that the literal in position "10" is now present.

It is possible, especially when there are few tags in the system and the tree is sparsely populated, that a search path can fail, i.e., no literal smaller than the one being searched for can be found. In this case a backup path is followed. A second search operates in parallel with the normal search to find the closest match in the case where no match is available from the primary search. It is not known if no match is available from the primary search until it operates. If a primary match is not available, the backup from the previous level is used—this is the next smallest bit in the parent node. If no such bit exists then the next smallest bit in the node two levels up is used. The tree will always have a smaller value available because the WFQ algorithm always produces tags larger than, or equal to, the smallest tag already in the system. When the desired backup bit is found the remaining search follows a path using the most significant bit in each node. The backup path will always return a match because a smaller tag marker value from previous levels will always be available, unless the tree is empty, in which case it will enter an initialization mode where only a write to the tree is necessary.

Fig. 5 shows a search conducted to find the closest match for a value of 110100. The search is successful in the first and second levels, however, in the third level there is no match in the "00" position, highlighted as Point "A." At this point, a search would usually be made in the third level node for a literal lower than the unsuccessful request, i.e., lower than, or to the left of "00." This is not possible and it is necessary to have a backup path. At each node two lookup operations take place. The primary search is for a matching literal, or the next smallest literal that exists. The secondary lookup is for the next literal less than that targeted by the primary search. This is illustrated at Point "B" in Fig. 5. When the original search fails at Point "A" this secondary backup match is followed.

> **Fig. 5.** Search illustrating backup path.

When using the backup path, the largest literals available are followed in each subsequent node. As can be seen from Fig. 5, this ensures that the match returned is the next lowest to the value search for. Note that in the second level of the original search no backup path is found because there is only one literal in that particular node. In such a case, the backup path from the previous level is always used. If there were literals "00" and "10" as indicated at Point "C," there would be a backup available in the second level and this path would be used in the event of a failed match in the subsequent node.

Having examined the search and insertion functions, the final consideration is removing entries from the tree. To understand this it is important to first understand the cyclical nature of generating finishing tags in the overall scheduler architecture. In order to prevent the values of the finishing tags increasing to infinity as time increases, the WFQ policy implemented resets the values it allocates to zero after a finite maximum value has been reached. By this time, a section of the smallest values previously allocated will have been serviced and removed from the system. These values will now be available to be reused again.

At any instant in time, new tags will be produced with a minimum value greater than the current lowest tag value, and a maximum in the region of the current highest tag value (it can obviously be greater than the current highest). Consequently, there will be a distribution profile of new tag values ranging approximately between the current lowest and highest tag values. This will be determined by the prevailing traffic profile, and it has been approximated using a normal distribution as shown in Fig. 6. The exact nature of the distribution will vary with the traffic profile experienced, for example, streaming VoIP is likely to produce a distribution weighted to the left, while a diverse mix of traffic will have a classic bell curve. As time progresses forward (as illustrated in Fig. 6) the average point will shift forward as tags are serviced, a range of values behind the current lowest tag value will be vacated. In the tree the related tag markers must be deleted so that the part of the tree they occupy can be reused when the WFQ calculation reaches the start of this range again.

> **Fig. 6.** Distribution of new tag values moves as time increases.

The top level of the tree is a single 16-bit node that effectively divides the total range of values of the tree into 16 separate sections of equal size. The shaded grey bar at the top of Fig. 6 illustrates this point. The light grey section highlighted by a dashed circle, shows an area of the tree that is not currently in active use. This section has just fallen outside the range of the current lowest tag value. All child nodes stemming from this bit are isolated and deleted at the same time.

The tree used in the real implementation has three levels and 16-bit nodes, the literals in this case are 4 bits and the branching factor is 16. The first two levels of the tree are relatively small, 272 bits in total, so these are implemented using registers. The third level is 4 kbits and is implemented using single port on-chip SRAM. This relatively small amount of on-chip memory allows very fast access to the data needed to operate the search function. The size of memory, in bits, required for each level of the tree (level memory, LM) is:

```
LM = 2^(log₂(b) · l) (2)
```

and it follows that the total memory required for the tree `M` can be expressed as:

```
M = Σᵢ₌₁ᵏ 2^(log₂(b) · i) (3)
```

where `l` = level number (level 1 is the tree root), `b` = branching factor, and `k` = total number of levels.

Therefore, using a multi-bit tree rather than a binary tree allows the search operation to be accelerated as well as requiring less memory.

### B. Matching Circuitry

The search operation required at each node is carried out using a set of custom designed matching circuits. A separate detailed investigation of custom circuit designs for finding the closest match in each node [13] examined look ahead based circuits, including a simple ripple cell approach, a standard look-ahead circuit as well as block look-ahead, skip & look-ahead, and select & look-ahead circuits. All circuits are based on modified adder carry chain acceleration techniques. Of the five accelerated matching techniques, a select & look-ahead approach was the fastest and most hardware efficient option available. When implemented separately on an FPGA platform using Altera Stratix II technology, the 16-bit circuit was capable of supporting lookup operations at speeds of 154 MHz. For packet scheduling this equates to more than 44 Gb/s for an average packet size of 140 bytes.

> **Fig. 7.** Comparison of matcher circuits speed (time delay) for different word lengths.

The graph in Fig. 7 summarizes the time taken for a search operation to be completed by a range of different matching circuit options. The curve shows how the select & look-ahead approach performs exceptionally well over a range of word widths up to 128 bits.

> **Fig. 8.** Comparison of matcher circuits area cost in terms of logic (in this case FPGA LUTs) for different word lengths.

Fig. 8 shows an area cost comparison for the circuits investigated, again the line shows the performance of the select & look-ahead approach, which has been used in the final architecture, where a 16-bit circuit is required.

### C. Tag Storage Memory

As already stated, tags are stored using a linked list format. Each entry, or link, in the list stores a tag value and a pointer to the next link. The next link will be the next biggest tag value in the memory and the link at the head of the list will be the smallest tag value. The list is implemented off chip, using SRAM. Currently, QDRII and RLD RAM versions are also under development. A key point to note is that the total number of tag values that can be stored in the linked list is limited only by the size of RAM used. The tag storage memory and the tag sort/retrieve circuit are independently scalable and configurable. The granularity or accuracy of sorting the tags depends on the tag sort/retrieve circuit, while the size (word width) and number of tags stored is decided by the size of RAM used for tag storage. The process of entering a new tag into the linked list requires four clock cycles, specifically two read and two write cycles to the memory. The process is illustrated in Fig. 9.

> **Fig. 9.** Writing a new tag into linked list.

1. An "empty" linked list is maintained to provide easy access to unused memory locations. One read access is required to find the next available unused location.
2. In the example, a tag with a value of 16 is being inserted. The search for tag 16 in the tree will return the location of tag 15 in the linked list. Link 15 is read from the list, which also has a pointer to link 17.
3. Link 15 is written back into the memory with a pointer to link 16.
4. Link 16 is written into the memory with a pointer to link 17, thus maintaining the order of the list and the continuity of the linked structure.

Initially all locations in the memory are empty and there are no links or pointers. Assuming there are 2ⁿ memory locations, a counter is incremented from 0 to 2ⁿ − 1 as new tags are added. Each new tag is allocated an address in the memory equal to the value of the counter, until the maximum counter value of 2ⁿ − 1 is reached. Before then, a number of tags will have been serviced and removed from the memory. When this happens, the pointer to the next tag in the linked list is held in a register, but the link itself is left unchanged and neither it nor its pointer is deleted. In this way, an "empty" list of unused links is maintained, with a pointer to the link at the head of the chain held in another register. After the counter reaches 2ⁿ − 1 there are effectively two separate lists distributed through the memory—one is the linked list of sorted tag values and the other is the empty list of available memory locations.

Fig. 10 shows a simplified example of the state of the tag storage memory soon after initialization. There are 12 memory locations available. Five of these are being used to store the linked list of sorted tags. Four show links that have been removed from the sorted list because their tags have been served and these now form the empty linked list. The final three memory locations have yet to be used. Assuming the locations are numbered 0–11, the counter will currently read "9" and the next tag to be added will be added in address location 9.

> **Fig. 10.** Linked list of tags and empty list, before initialization counter has reached maximum capacity.

It is possible that the tag storage memory will simultaneously receive a request to store a new tag at the same time as a request to read and remove the smallest tag. This process can be achieved in the four clock cycles already allocated. Instead of reading a link from the empty linked list, the smallest tag ("6" in Fig. 10) is accessed instead. Its forward link to the next value is stored in a register so that the physical position of the smallest tag in the memory is always known. The link itself can be reused to store the incoming new tag using the same process outlined in Fig. 9.

One final, important property of the linked list arrangement should be noted. Depending on the accuracy of the WFQ computation, tag values may be rounded off so that theoretically two or more tags of the same value can exist in the scheduler at one time. The sequential storage nature of the linked list allows a first come first served policy to be applied in this case.

### D. Translation Table

By using a linked list and a tree, the search and store functions of the sort/retrieve circuit are separated. The linked list can, therefore, store any number of tags, independent from the granularity of search possible with the tree. The translation table provides the essential bridge between these two components allowing them to be separately scalable. The table records the physical memory address of each tag in the linked list and is addressed using the tag value itself. For each possible tag value that the tree can store, there must be a corresponding entry in the address translation table. The size of translation table required can therefore be expressed as follows:

```
T = 2^(w·l)      (4)
```

where `T` = number of entries in translation table, `w` = width of nodes in multi-bit tree, `l` = number of levels in tree.

The granularity of the tree search determines the size of the translation table, so the translation table can be considered part of the search function. As discussed in Section III-C, two or more tags of the same value can exist. In this case, the translation table will track the most recent tag to have entered the linked list. It is this property specifically that allows the search and store functions to be independent and separately scalable. Fig. 11 shows how duplicate entries are treated.

> **Fig. 11.** Inserting duplicate tag values.

In Step 1), the tree will search and find the position of the tag with the value "5" and the new tag will be inserted after the existing tag "5." When the second "5" is inserted into the list, the pointer in the translation table is changed from the position of the older "5" to the position of the newest "5." In the second step when tag "6" is to be added to the list the tree search will return the position of the newest tag "5" and the "6" will be inserted after it. Following this method ensures that any result from the search tree will always be valid since the corresponding entry in the translation table will always indicate the most recently added of any duplicate value.

---

## IV. Implementation

The layout has been generated and post-layout verification has been carried out. Functional verification has been achieved using field-programmable gate array (FPGA) prototyping of the hardware, including full deployment of the complete scheduler architecture described in Fig. 1. It is not intended that the circuit presented operates as a standalone SoC in itself, rather it is a key core and part of the scheduler presented. The circuit in Fig. 12 was implemented using UMC 130-nm standard cell technology. The design was described in VHDL and synthesized using Synopsys Physical Compiler. Place and routing of the layout was carried out with Cadence SoC Encounter.

> **TABLE II. Post Layout Synthesis Results (Cadence SoC Encounter)**

> *（注：原始文本中该表的具体数值不完整；正文描述的关键事实如下）*
> - 工艺：UMC 130 nm 标准单元
> - 片内存储器：32 个小规模分布式存储块（树的底层）+ 8 个较大存储块（地址转换表）
> - 存储块功耗相对较低，大部分功耗来自查找逻辑及相关互连
> - 吞吐量：超过 35.8 M packets/s（平均包长 140 字节 ⇒ 40 Gb/s 线速）

The chip layout shows eight large blocks of memory on the left-hand side which store the address translation table and a smaller cluster of memory on the bottom right that stores the search tree. Most of the logic required for the chip is located along the right side of the layout. The results show that the power consumption of the memory blocks is comparatively low, with the majority due to the lookup logic and associated interconnect.

> **Fig. 12.** Physical layout of tag sort/retrieve circuit.

By using external SRAM for the tag storage memory (see Fig. 1), it is possible to store and service 30 million packets at any instance in time. The number of sessions supported by the scheduler is scalable up to 8 million concurrent sessions (virtual queues). With the SoC circuit generated, a throughput of over 35.8 million packets per second is possible. Based on a conservative estimate for an average IP packet size of 140 bytes, the circuit can operate at line speeds of 40 Gb/s. Non-published work extracted from datasheets and technical notes of semiconductor vendors offering WFQ based solutions to router vendors indicate throughput rates for packet scheduling and traffic management in the region of 5–10 Gb/s. Despite the unavailability of more specific relevant performance data, since this is a bottleneck area it can be suggested that our approach outperforms the state of the art in the field by a factor of approximately 4.

---

## V. Conclusion

This paper describes the implementation of a hardware architecture for high performance IP traffic management. The fair queueing scheduling policy is based on well known packet scheduling algorithms conventionally implemented in software. This research focuses on a novel architecture used to facilitate the operation of these algorithms at high speed. The architecture itself is not based on an algorithm, rather the innovation lies in the derivation of an efficient circuit architecture comprised of distributed memories allowing parallel and pipelined processing.

A standard cell based circuit design has been presented that enables high speed packet sorting for a WFQ based Internet packet scheduler, implemented entirely in hardware and capable of supporting line speeds of 40 Gb/s. The novel architecture has a number of key advantages over the previous state of the art in this area. In particular this includes a fixed and predictable lookup time and the ability to guarantee that the lowest tag value will always be found. Furthermore, having analyzed a range of alternative options, including standard software arrangements, it has been shown that the multi-bit tree-based design presented offers the optimum solution available, both in terms of speed and performance.

Based on overall performance metrics, such as the numbers of virtual queues, sessions and throughput supported, it can be estimated that our solution can outperform the current technology available in commercial routers by up to an order of magnitude. Classical physical layer products such as SONET/SDH support 10–40 Gb/s, however network layer related products such as IP are currently in the market operating at 2.5 Gb/s per channel, usually running on 10–40 Gb/s physical layer. Products are currently being developed for 10 Gb/s channels and in coming years it is believed that full 40 Gb/s channels on IP layer will become the benchmark. The presented architecture and its standard cell implementation represent a state-of-the-art solution for next generation 40 Gb/s traffic management. Due to the flexible design used, it is further scalable for future terabit QoS router technologies.

The impact of this unique architecture is that it is scalable in terms of the number of tags, sessions, and packets supported, delivering high performance with low latency. It is therefore suitable for throughput speeds beyond 40 Gb/s, which is beyond current industry capabilities.