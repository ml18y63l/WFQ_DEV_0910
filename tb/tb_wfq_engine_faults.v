// Full-engine fault atomicity: compare all memories and architectural registers.
`timescale 1ns/1ps
module tb_wfq_engine_faults;
parameter integer PTR_WIDTH=10;
parameter integer MEM_DEPTH=1024;
parameter integer FLOW_ID_WIDTH=9;
parameter integer ISSUE_INTERVAL=5;
parameter integer TAG_WIDTH=12;
parameter integer EPOCH_WIDTH=16;
parameter integer LITERAL_WIDTH=4;
`include "wfq_clog2.vh"
localparam integer A=wfq_clog2(MEM_DEPTH);
localparam integer C=wfq_clog2(MEM_DEPTH+1);
localparam integer W=28+FLOW_ID_WIDTH;
localparam integer L=PTR_WIDTH+1;
localparam integer P_LSB=L;
localparam integer N_LSB=2*L;
reg clk,rstn,insert_val,extract_req,extract_out_ready;
reg [EPOCH_WIDTH-1:0] insert_epoch;
reg [TAG_WIDTH-1:0] insert_tag;
reg [FLOW_ID_WIDTH-1:0] insert_flow_id;
wire insert_ready,insert_commit,insert_epoch_blocked,extract_ready,extract_commit,extract_val;
wire [EPOCH_WIDTH-1:0] min_epoch_out;
wire [TAG_WIDTH-1:0] min_tag_out;
wire [FLOW_ID_WIDTH-1:0] min_tag_flow_id;
wire init_done,empty,full,busy,idle,fault;
wire [C-1:0] queue_level;
wire [3:0] fault_code;
wfq_tag_sort_engine #(
    .TAG_WIDTH(TAG_WIDTH),.LITERAL_WIDTH(LITERAL_WIDTH),.EPOCH_WIDTH(EPOCH_WIDTH),
    .PTR_WIDTH(PTR_WIDTH),.MEM_DEPTH(MEM_DEPTH),
    .FLOW_ID_WIDTH(FLOW_ID_WIDTH),.ISSUE_INTERVAL(ISSUE_INTERVAL)
) u_dut (
    .clk(clk),.rstn(rstn),
    .insert_val(insert_val),.insert_ready(insert_ready),.insert_epoch(insert_epoch),
    .insert_tag(insert_tag),.insert_flow_id(insert_flow_id),
    .insert_commit(insert_commit),.insert_epoch_blocked(insert_epoch_blocked),
    .extract_req(extract_req),.extract_ready(extract_ready),
    .extract_commit(extract_commit),.extract_val(extract_val),.extract_out_ready(extract_out_ready),
    .min_epoch_out(min_epoch_out),.min_tag_out(min_tag_out),.min_tag_flow_id(min_tag_flow_id),
    .init_done(init_done),.empty(empty),.full(full),.queue_level(queue_level),
    .busy(busy),.idle(idle),.fault(fault),.fault_code(fault_code)
);

integer id,i,k,expected,checks,fault_cases,reset_cases,null_cases,stage,watchdog;
integer old_live,old_free,old_reserved,old_rsp,old_rsp_reserved;
reg [L-1:0] saved_head,saved_tail,saved_head_next,bh0,bt0,bh1,bt1;
reg saved_cache;
reg [W-1:0] saved_head_payload,saved_output;
reg [11:0] bmin0,bmax0,bmin1,bmax1;
reg [C-1:0] bc0,bc1;
reg [15:0] be0,be1,base;
reg [1:0] bv;
reg [31:0] roots;
reg [511:0] parents;
reg [15:0] leaves [0:511];
reg [C-1:0] counts [0:8191];
reg [L-1:0] translations [0:8191];
reg [W-1:0] data_words [0:MEM_DEPTH-1];
reg [L-1:0] next_words [0:MEM_DEPTH-1];
reg [PTR_WIDTH-1:0] free_words [0:MEM_DEPTH-1];
reg [PTR_WIDTH-1:0] p10,p20,p30,p40,p35;
reg [PTR_WIDTH-1:0] bad_ptr;
reg [3:0] first_code;
reg [L-1:0] null_with_bits;

task check;
    input ok;
    input [1023:0] reason;
    begin
        checks=checks+1;
        if(ok!==1'b1) begin
            $display("FAIL engine fault ptr=%0d depth=%0d id=%0d stage=%0d reason=%0s expected=%0d fault=%0d event=%0d list=%0d meta=%0d context=%0d",
                     PTR_WIDTH,MEM_DEPTH,id,stage,reason,expected,fault_code,u_dut.u_resource.error_code,
                     u_dut.list_error,u_dut.metadata_error,u_dut.context_error);
            $finish;
        end
    end
endtask
task tick;
    begin
        #4;clk=1;#1;#4;clk=0;
    end
endtask
task initialize;
    begin
        rstn=0;insert_val=0;extract_req=0;extract_out_ready=0;
        insert_epoch=10;insert_tag=0;insert_flow_id=0;
        tick;rstn=1;watchdog=0;
        while(!init_done) begin
            tick;watchdog=watchdog+1;
            check(!insert_commit && !extract_commit && !extract_val && !busy,"reset/init masks old work");
            if(watchdog>65540) begin
                check(0,"init timeout");
            end
        end
        #1;check(!fault && empty && queue_level==0 && !busy,"clean initialization");
    end
endtask
task begin_put;
    input [11:0] tag;
    begin
        insert_val=1;extract_req=0;insert_epoch=10;insert_tag=tag;insert_flow_id=tag;#2;
        watchdog=0;
        while(!insert_ready) begin
            tick;#2;watchdog=watchdog+1;
            check(!fault && watchdog<20,"fixture insert acceptance");
        end
        tick;insert_val=0;#1;
    end
endtask
task put;
    input [11:0] tag;
    begin
        begin_put(tag);
        case(tag)
            10: p10=u_dut.alloc_ptr;
            20: p20=u_dut.alloc_ptr;
            30: p30=u_dut.alloc_ptr;
            40: p40=u_dut.alloc_ptr;
            35: p35=u_dut.alloc_ptr;
        endcase
        repeat(4) begin
            tick;check(!fault,"fixture insertion");
        end
        check(insert_commit,"fixture E4 commit");
    end
endtask
task begin_take;
    begin
        insert_val=0;extract_req=1;#2;watchdog=0;
        while(!extract_ready) begin
            tick;#2;watchdog=watchdog+1;
            check(!fault && watchdog<20,"fixture extract acceptance");
        end
        tick;extract_req=0;#1;
    end
endtask
task seed_state;
    begin
        put(10);put(20);put(30);put(40);
        begin_take;tick;check(extract_commit && !fault,"fixture E1 extraction");
        repeat(6) tick;
        check(queue_level==3 && extract_val && min_tag_out==10,"live list plus old response");
    end
endtask
task snapshot;
    begin
        #1;
        old_live=queue_level;old_free=u_dut.u_resource.free_count;
        old_reserved=u_dut.u_resource.alloc_reserved;
        old_rsp=u_dut.rsp_count;old_rsp_reserved=u_dut.rsp_reserved;
        saved_output={min_epoch_out,min_tag_out,min_tag_flow_id};
        saved_head=u_dut.u_list.head_d;saved_tail=u_dut.u_list.tail_d;
        saved_cache=u_dut.u_list.cache_valid_d;saved_head_payload=u_dut.head_payload;
        saved_head_next=u_dut.u_list.head_next_d;
        bh0=u_dut.u_list.bank0_head_d;bt0=u_dut.u_list.bank0_tail_d;
        bh1=u_dut.u_list.bank1_head_d;bt1=u_dut.u_list.bank1_tail_d;
        bmin0=u_dut.u_list.bank0_min_d;bmax0=u_dut.u_list.bank0_max_d;
        bmin1=u_dut.u_list.bank1_min_d;bmax1=u_dut.u_list.bank1_max_d;
        bc0=u_dut.bank0_count;bc1=u_dut.bank1_count;
        be0=u_dut.bank0_epoch;be1=u_dut.bank1_epoch;base=u_dut.base_epoch;
        bv=u_dut.u_resource.u_epoch.bank_valid;
        roots=u_dut.u_metadata.l1_flat;parents=u_dut.u_metadata.l2_flat;
        for(i=0;i<8192;i=i+1) begin
            counts[i]=u_dut.u_metadata.u_rc.u_ram.mem_d[i];
            translations[i]=u_dut.u_metadata.u_tt.u_ram.mem_d[i];
        end
        for(i=0;i<512;i=i+1) begin
            leaves[i]=u_dut.u_metadata.u_leaf.mem_d[i];
        end
        for(i=0;i<MEM_DEPTH;i=i+1) begin
            data_words[i]=u_dut.u_list.u_data.mem_d[i];
            next_words[i]=u_dut.u_list.u_next.mem_d[i];
            free_words[i]=u_dut.u_resource.u_free.u_ram.mem_d[i];
        end
    end
endtask
task no_writes;
    begin
        check(!u_dut.u_metadata.rc_write_en && !u_dut.u_metadata.tt_write_en &&
              !u_dut.u_metadata.l1_write_en && !u_dut.u_metadata.l2_write_en &&
              !u_dut.u_metadata.leaf_write_en && !u_dut.u_list.u_data.write_en &&
              !u_dut.u_list.next_write_en && !u_dut.u_resource.u_free.ram_write_en,
              "all physical RAM/register write enables inhibited");
    end
endtask
task unchanged;
    begin
        check(queue_level===old_live[C-1:0] && u_dut.u_resource.free_count===old_free[C-1:0] &&
              u_dut.u_resource.alloc_reserved===old_reserved[C-1:0],"capacity atomicity");
        check(u_dut.rsp_count===old_rsp[1:0] && u_dut.rsp_reserved===old_rsp_reserved[1:0] &&
              {min_epoch_out,min_tag_out,min_tag_flow_id}===saved_output,"response atomicity");
        check(u_dut.u_list.head_d===saved_head && u_dut.u_list.tail_d===saved_tail &&
              u_dut.u_list.cache_valid_d===saved_cache && u_dut.head_payload===saved_head_payload &&
              u_dut.u_list.head_next_d===saved_head_next,"global list/cache atomicity");
        check(u_dut.u_list.bank0_head_d===bh0 && u_dut.u_list.bank0_tail_d===bt0 &&
              u_dut.u_list.bank1_head_d===bh1 && u_dut.u_list.bank1_tail_d===bt1 &&
              u_dut.u_list.bank0_min_d===bmin0 && u_dut.u_list.bank0_max_d===bmax0 &&
              u_dut.u_list.bank1_min_d===bmin1 && u_dut.u_list.bank1_max_d===bmax1 &&
              u_dut.bank0_count===bc0 && u_dut.bank1_count===bc1 &&
              u_dut.bank0_epoch===be0 && u_dut.bank1_epoch===be1 &&
              u_dut.base_epoch===base && u_dut.u_resource.u_epoch.bank_valid===bv,"bank atomicity");
        check(u_dut.u_metadata.l1_flat===roots && u_dut.u_metadata.l2_flat===parents,"upper Trie atomicity");
        for(i=0;i<8192;i=i+1) begin
            check(u_dut.u_metadata.u_rc.u_ram.mem_d[i]===counts[i],"all RC unchanged");
            check(u_dut.u_metadata.u_tt.u_ram.mem_d[i]===translations[i],"all TT unchanged");
        end
        for(i=0;i<512;i=i+1) begin
            check(u_dut.u_metadata.u_leaf.mem_d[i]===leaves[i],"all L3 unchanged");
        end
        for(i=0;i<MEM_DEPTH;i=i+1) begin
            check(u_dut.u_list.u_data.mem_d[i]===data_words[i],"all DATA unchanged");
            check(u_dut.u_list.u_next.mem_d[i]===next_words[i],"all NEXT unchanged");
            check(u_dut.u_resource.u_free.u_ram.mem_d[i]===free_words[i],"all FREE unchanged");
        end
    end
endtask
initial begin
    clk=0;checks=0;fault_cases=0;reset_cases=0;null_cases=0;stage=0;
    for(id=0;id<30;id=id+1) begin
        if(PTR_WIDTH>A || !((id>=7 && id<=12)||id==29)) begin
            initialize;seed_state;expected=6;
            bad_ptr=MEM_DEPTH;
            case(id)
                0: begin
                    u_dut.u_metadata.u_rc.u_ram.mem_d[35]=MEM_DEPTH;
                    begin_put(35);expected=1;
                end
                1: begin
                    u_dut.u_metadata.u_rc.u_ram.mem_d[20]=0;
                    begin_take;expected=1;
                end
                2: begin
                    u_dut.u_metadata.u_tt.u_ram.mem_d[30]=0;
                    begin_put(35);repeat(2) tick;expected=2;
                end
                3: begin
                    u_dut.u_metadata.u_leaf.mem_d[1][4]=0;
                    begin_take;expected=2;
                end
                4: begin
                    u_dut.u_list.cache_valid_d=0;
                    extract_req=1;expected=3;
                end
                5: begin
                    u_dut.u_list.head_next_d=0;
                    extract_req=1;expected=3;
                end
                6: begin
                    u_dut.u_list.head_payload_d[W-1 -: 16]=11;
                    expected=4;
                end
                7: begin
                    u_dut.u_resource.u_free.u_ram.mem_d[MEM_DEPTH-4]=bad_ptr;
                    begin_put(35);expected=7;
                end
                8: begin
                    bad_ptr=MEM_DEPTH+MEM_DEPTH/2-1;
                    u_dut.u_metadata.u_tt.u_ram.mem_d[30]={1'b1,bad_ptr};
                    begin_put(35);repeat(2) tick;expected=7;
                end
                9: begin
                    bad_ptr={PTR_WIDTH{1'b1}};
                    u_dut.u_list.u_next.mem_d[p30]={1'b1,bad_ptr};
                    begin_put(35);repeat(3) tick;expected=7;
                end
                10: begin
                    begin_put(35);repeat(4) tick;
                    u_dut.u_list.pending0_d[P_LSB +: L]={1'b1,bad_ptr};expected=7;
                end
                11: begin
                    begin_put(35);repeat(4) tick;
                    u_dut.u_list.pending0_d[N_LSB +: PTR_WIDTH]=bad_ptr;expected=7;
                end
                12: begin
                    u_dut.u_list.head_next_d={1'b1,bad_ptr};
                    extract_req=1;expected=7;
                end
                13: begin
                    u_dut.u_list.u_data.mem_d[p30][W-1 -: 16]=11;
                    begin_take;expected=4;
                end
                14: begin
                    u_dut.u_list.u_next.mem_d[p30]=0;
                    begin_take;expected=3;
                end
                15: begin
                    begin_take;
                    force u_dut.u_list.data_read_valid=1'b0;
                end
                16: begin
                    begin_put(35);repeat(3) tick;
                    force u_dut.u_list.next_read_valid=1'b0;
                end
                17: begin
                    begin_put(35);repeat(3) tick;
                    u_dut.u_list.next_context_d=1'b1;
                end
                18: begin
                    begin_put(35);
                    force u_dut.alloc_context=1'b1;
                end
                19: begin
                    begin_put(35);repeat(2) tick;
                    force u_dut.pred_context=1'b1;
                end
                20: begin
                    begin_put(35);repeat(3) tick;
                    u_dut.u_list.body_valid_d=0;
                end
                21: begin
                    begin_put(35);repeat(4) tick;
                    u_dut.u_list.pending_valid_d=0;
                end
                22: begin
                    begin_put(35);repeat(4) tick;
                    u_dut.u_commit.committed_d=0;
                end
                23: begin
                    begin_put(35);
                    force u_dut.u_metadata.rc_read_count=MEM_DEPTH;
                    u_dut.u_list.cache_valid_d=0;expected=1;
                end
                24: begin
                    begin_put(35);repeat(3) tick;
                    force u_dut.u_list.next_read_data=0;
                    u_dut.u_resource.u_response.reserved_d=3;expected=3;
                end
                25: begin
                    begin_put(35);repeat(3) tick;
                    force u_dut.u_list.patch_write_intent=1'b1;
                end
                26: begin
                    u_dut.u_commit.valid_d=3;
                    u_dut.u_commit.age0_d=0;u_dut.u_commit.age1_d=0;
                    insert_val=1;insert_tag=35;
                end
                27: begin
                    begin_put(35);repeat(3) tick;
                    force u_dut.metadata_due=1'b0;
                end
                28: begin
                    begin_take;
                    u_dut.u_resource.u_free.free_count_d=MEM_DEPTH;expected=5;
                end
                29: begin
                    begin_take;
                    u_dut.u_list.old_head_d={1'b1,bad_ptr};expected=7;
                end
            endcase
            #2;
            check(!fault && u_dut.u_resource.error_code==expected,"pre-edge expected minimum code");
            check(!u_dut.cycle_allow && !insert_ready && !extract_ready &&
                  !u_dut.commit_fire,"common gate blocks acceptance and commit");
            check(!u_dut.u_list.data_read_en && !u_dut.u_list.next_read_en,"node reads inhibited before narrowing");
            no_writes;snapshot;tick;
            check(fault && fault_code==expected && !insert_commit && !extract_commit,"sticky fault at edge");
            unchanged;no_writes;
            release u_dut.u_list.data_read_valid;
            release u_dut.u_list.next_read_valid;
            release u_dut.alloc_context;
            release u_dut.pred_context;
            release u_dut.u_metadata.rc_read_count;
            release u_dut.u_list.next_read_data;
            release u_dut.u_list.patch_write_intent;
            release u_dut.metadata_due;
            force u_dut.external_error=4'd1;
            insert_val=1;extract_req=1;repeat(3) tick;
            check(fault_code==expected && !insert_ready && !extract_ready && !idle,"sticky first and fail-stop");
            unchanged;no_writes;
            check(extract_val && {min_epoch_out,min_tag_out,min_tag_flow_id}===saved_output,"old response retained");
            extract_out_ready=1;tick;
            check(!extract_val && queue_level==old_live && u_dut.u_resource.free_count==old_free,
                  "old response drains without freeing a node again");
            release u_dut.external_error;
            fault_cases=fault_cases+1;
        end
    end

    // Invalid links ignore all pointer bits, even in wider pointer configurations.
    id=30;initialize;put(10);repeat(3) tick;
    null_with_bits={1'b0,{PTR_WIDTH{1'b1}}};
    u_dut.u_list.u_next.mem_d[p10]=null_with_bits;
    put(20);repeat(3) tick;
    check(!fault,"NULL successor pointer ignored after tail/head insertion");
    extract_out_ready=1;
    begin_take;tick;repeat(5) tick;
    check(!fault && queue_level==1 && !u_dut.u_list.head_next_d[PTR_WIDTH],"NULL prefetch accepted");
    begin_take;tick;repeat(5) tick;
    check(!fault && empty && idle,"NULL bits never dereferenced");
    null_cases=null_cases+1;

    // Reset at insert E4/E5/E6 and extract E1/E2, followed by a clean new stream.
    for(stage=4;stage<=6;stage=stage+1) begin
        id=30+stage;initialize;seed_state;begin_put(35);
        repeat(stage-1) tick;
        rstn=0;#2;
        check(!insert_commit && !extract_commit && !extract_val && !busy &&
              !init_done && !insert_ready && !extract_ready,"asynchronous reset near insert boundary");
        initialize;put(10);extract_out_ready=1;begin_take;tick;repeat(6) tick;
        check(!fault && empty && idle,"post-reset insert recovery");
        reset_cases=reset_cases+1;
    end
    for(stage=1;stage<=2;stage=stage+1) begin
        id=40+stage;initialize;seed_state;begin_take;
        repeat(stage-1) tick;
        rstn=0;#2;
        check(!extract_commit && !extract_val && !busy && !init_done,"reset near extract boundary");
        initialize;put(10);extract_out_ready=1;begin_take;tick;repeat(6) tick;
        check(!fault && empty && idle,"post-reset extract recovery");
        reset_cases=reset_cases+1;
    end
    $display("PASS tb_wfq_engine_faults ptr=%0d depth=%0d faults=%0d reset_cases=%0d null_cases=%0d checks=%0d",
             PTR_WIDTH,MEM_DEPTH,fault_cases,reset_cases,null_cases,checks);
    $finish;
end
initial begin
    #100000000;
    $display("FAIL engine faults watchdog");
    $finish;
end
endmodule
