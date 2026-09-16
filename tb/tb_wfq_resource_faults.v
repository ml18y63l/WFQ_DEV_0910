// Actual state/return fault injection with full FREE image and atomic-state checks.
`timescale 1ns/1ps
module tb_wfq_resource_faults;
parameter integer PTR_WIDTH = 10;
parameter integer MEM_DEPTH = 1024;
parameter integer FLOW_ID_WIDTH = 9;
parameter integer ISSUE_INTERVAL = 5;
`include "wfq_clog2.vh"
localparam integer ADDR_WIDTH = wfq_clog2(MEM_DEPTH);
localparam integer COUNT_WIDTH = wfq_clog2(MEM_DEPTH+1);
localparam integer PAYLOAD_WIDTH = 28+FLOW_ID_WIDTH;
reg clk, rstn, halt, insert_val, extract_req, request_context;
reg [15:0] insert_epoch;
reg context_available, path_ready;
reg commit_req, commit_insert, commit_context;
reg [15:0] commit_epoch;
reg [PTR_WIDTH-1:0] release_ptr;
reg [PAYLOAD_WIDTH-1:0] response_payload;
reg [3:0] external_error_code;
reg extract_out_ready;
wire init_done, init_guard, init_free_write_en;
wire [ADDR_WIDTH-1:0] init_free_write_addr;
wire [PTR_WIDTH-1:0] init_free_write_data;
wire insert_ready, extract_ready, insert_fire, extract_fire;
wire insert_epoch_blocked, issue_open;
wire alloc_valid, alloc_context;
wire [PTR_WIDTH-1:0] alloc_ptr;
wire commit_due, commit_fire, cycle_allow;
wire extract_val;
wire [PAYLOAD_WIDTH-1:0] extract_payload;
wire [1:0] rsp_count, rsp_reserved;
wire [COUNT_WIDTH-1:0] free_count, alloc_reserved, queue_level;
wire empty, full;
wire [15:0] base_epoch, bank0_epoch, bank1_epoch;
wire [1:0] bank_valid;
wire [COUNT_WIDTH-1:0] bank0_count, bank1_count;
wire error_valid, fault;
wire [3:0] error_code, fault_code;

wfq_init_ctrl #(.PTR_WIDTH(PTR_WIDTH), .MEM_DEPTH(MEM_DEPTH)) u_init (
    .clk(clk), .rstn(rstn), .init_done(init_done), .init_guard(init_guard),
    .meta_write_en(), .meta_write_addr(), .l1_write_en(), .l1_write_addr(),
    .l2_write_en(), .l2_write_addr(), .l3_write_en(), .l3_write_addr(),
    .free_write_en(init_free_write_en), .free_write_addr(init_free_write_addr),
    .free_write_data(init_free_write_data)
);

wfq_resource_ctrl #(
    .PTR_WIDTH(PTR_WIDTH), .MEM_DEPTH(MEM_DEPTH),
    .FLOW_ID_WIDTH(FLOW_ID_WIDTH), .ISSUE_INTERVAL(ISSUE_INTERVAL)
) u_dut (
    .clk(clk), .rstn(rstn), .init_done(init_done), .init_guard(init_guard),
    .init_free_write_en(init_free_write_en),
    .init_free_write_addr(init_free_write_addr), .init_free_write_data(init_free_write_data),
    .halt(halt), .insert_val(insert_val), .insert_epoch(insert_epoch),
    .extract_req(extract_req), .request_context(request_context),
    .context_available(context_available), .path_ready(path_ready),
    .insert_ready(insert_ready), .extract_ready(extract_ready),
    .insert_fire(insert_fire), .extract_fire(extract_fire),
    .insert_epoch_blocked(insert_epoch_blocked), .issue_open(issue_open),
    .alloc_valid(alloc_valid), .alloc_context(alloc_context), .alloc_ptr(alloc_ptr),
    .commit_req(commit_req), .commit_insert(commit_insert),
    .commit_context(commit_context), .commit_epoch(commit_epoch),
    .release_ptr(release_ptr), .response_payload(response_payload),
    .external_error_code(external_error_code), .commit_due(commit_due),
    .commit_fire(commit_fire), .cycle_allow(cycle_allow),
    .extract_out_ready(extract_out_ready), .extract_val(extract_val),
    .extract_payload(extract_payload), .rsp_count(rsp_count), .rsp_reserved(rsp_reserved),
    .free_count(free_count), .alloc_reserved(alloc_reserved), .queue_level(queue_level),
    .empty(empty), .full(full), .base_epoch(base_epoch), .bank_valid(bank_valid),
    .bank0_epoch(bank0_epoch), .bank1_epoch(bank1_epoch),
    .bank0_count(bank0_count), .bank1_count(bank1_count),
    .error_valid(error_valid), .error_code(error_code), .fault(fault), .fault_code(fault_code)
);

integer id,i,k,checks,fault_cases,cancel_cases,expected;
reg saved_context;
reg [COUNT_WIDTH-1:0] saved_free,saved_reserved,saved_level,saved_b0,saved_b1;
reg [15:0] saved_base,saved_e0,saved_e1;
reg [1:0] saved_valid,saved_count,saved_rsp_reserved;
reg [PAYLOAD_WIDTH-1:0] saved_response;
reg [PTR_WIDTH-1:0] saved_ram [0:MEM_DEPTH-1];
reg [3:0] saved_first;
reg saved_rr;
reg [2:0] saved_gap;

task check;
    input ok;
    input [767:0] reason;
    begin
        checks=checks+1;
        if(ok!==1'b1) begin
            $display("FAIL resource faults ptr=%0d depth=%0d id=%0d reason=%0s expected=%0d event=%0d sticky=%0d",
                     PTR_WIDTH,MEM_DEPTH,id,reason,expected,error_code,fault_code);
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
        rstn=0;halt=0;insert_val=0;extract_req=0;request_context=0;
        insert_epoch=10;context_available=1;path_ready=1;
        commit_req=0;commit_insert=0;commit_context=0;commit_epoch=10;
        release_ptr=0;response_payload=0;external_error_code=0;extract_out_ready=0;
        tick;rstn=1;
        while(!init_done) begin
            tick;
        end
        #1;
        check(free_count==MEM_DEPTH && !fault && empty && !extract_val,"reset/guard");
    end
endtask

task begin_insert;
    begin
        insert_val=1;extract_req=0;insert_epoch=10;request_context=~request_context;
        #1;
        while(!insert_ready) begin
            tick;
        end
        saved_context=request_context;
        tick;
        insert_val=0;
        commit_insert=1;commit_context=saved_context;commit_epoch=10;
    end
endtask

task finish_insert;
    begin
        // Caller is immediately after E0.
        repeat(3) tick;
        commit_req=1;#1;
        check(commit_due && commit_fire && !error_valid,"fixture insert commit");
        tick;commit_req=0;
    end
endtask

task begin_extract;
    begin
        insert_val=0;extract_req=1;request_context=~request_context;#1;
        while(!extract_ready) begin
            tick;
        end
        saved_context=request_context;
        tick;
        extract_req=0;commit_insert=0;commit_context=saved_context;commit_epoch=10;
        release_ptr=MEM_DEPTH-1;
        response_payload={16'd10,12'h123,{FLOW_ID_WIDTH{1'b1}}};
        commit_req=1;
    end
endtask

task seed_state;
    begin
        begin_insert;finish_insert;
        begin_insert;finish_insert;
        begin_extract;#1;check(commit_fire,"fixture extract");tick;commit_req=0;
        repeat(5) tick;
        check(queue_level==1 && rsp_count==1 && free_count==MEM_DEPTH-1,"fixture live and old response");
    end
endtask

task snapshot;
    begin
        #1;
        saved_free=free_count;saved_reserved=alloc_reserved;saved_level=queue_level;
        saved_b0=bank0_count;saved_b1=bank1_count;saved_base=base_epoch;
        saved_e0=bank0_epoch;saved_e1=bank1_epoch;saved_valid=bank_valid;
        saved_count=rsp_count;saved_rsp_reserved=rsp_reserved;saved_response=extract_payload;
        saved_rr=u_dut.u_admission.prefer_insert_d;saved_gap=u_dut.u_admission.gap_d;
        for(i=0;i<MEM_DEPTH;i=i+1) begin
            saved_ram[i]=u_dut.u_free.u_ram.mem_d[i];
        end
    end
endtask

task unchanged;
    begin
        check(free_count===saved_free && alloc_reserved===saved_reserved &&
              queue_level===saved_level,"atomic capacity");
        check(bank0_count===saved_b0 && bank1_count===saved_b1 && base_epoch===saved_base &&
              bank0_epoch===saved_e0 && bank1_epoch===saved_e1 && bank_valid===saved_valid,"atomic epochs");
        check(rsp_count===saved_count && rsp_reserved===saved_rsp_reserved &&
              extract_payload===saved_response,"atomic response");
        check(u_dut.u_admission.prefer_insert_d===saved_rr &&
              u_dut.u_admission.gap_d===saved_gap,"atomic RR/cooldown");
        for(i=0;i<MEM_DEPTH;i=i+1) begin
            check(u_dut.u_free.u_ram.mem_d[i]===saved_ram[i],"no partial FREE write");
        end
    end
endtask

initial begin
    clk=0;checks=0;fault_cases=0;cancel_cases=0;expected=0;
    for(id=0;id<20;id=id+1) begin
        if(((id!=12)&&(id!=13))||(PTR_WIDTH>ADDR_WIDTH)) begin
            initialize;
            seed_state;
            expected=6;
            case(id)
                0: begin
                    u_dut.u_free.free_count_d=MEM_DEPTH+1;
                    expected=5;
                end
                1: begin
                    begin_insert;repeat(3) tick;commit_req=1;
                    u_dut.u_free.reserved_d=0;
                    u_dut.u_free.free_count_d=MEM_DEPTH-1;
                    expected=5;
                end
                2: begin
                    u_dut.u_epoch.epoch0_d=11;
                    expected=4;
                end
                3: begin
                    u_dut.u_epoch.valid_d=0;
                    expected=4;
                end
                4: begin
                    u_dut.u_response.reserved_d=2;
                    expected=5;
                end
                5: begin
                    begin_insert;repeat(3) tick;commit_req=1;
                    commit_context=~saved_context;
                end
                6: begin
                    begin_insert;repeat(3) tick;
                    commit_req=0;
                end
                7: begin
                    begin_insert;tick;commit_req=1;
                end
                8: begin
                    insert_val=1;context_available=0;
                end
                9: begin
                    insert_val=1;path_ready=0;
                end
                10: begin
                    begin_insert;
                    force u_dut.u_free.ram_read_valid=1'b0;
                end
                11: begin
                    begin_insert;repeat(3) tick;commit_req=1;
                    commit_epoch=11;
                    expected=4;
                end
                12: begin
                    u_dut.u_free.u_ram.mem_d[MEM_DEPTH-2]=MEM_DEPTH;
                    begin_insert;
                    expected=7;
                end
                13: begin
                    begin_extract;release_ptr=MEM_DEPTH;
                    expected=7;
                end
                14: begin
                    begin_extract;
                    response_payload={16'd11,12'h123,{FLOW_ID_WIDTH{1'b1}}};
                    expected=4;
                end
                15: begin
                    begin_extract;
                    u_dut.u_epoch.epoch0_d=11;
                    u_dut.u_response.reserved_d=3;
                    external_error_code=1;
                    expected=1;
                end
                16: begin
                    begin_extract;
                    u_dut.u_response.reserved_d=3;
                    external_error_code=3;
                    expected=3;
                end
                17: begin
                    begin_insert;repeat(3) tick;commit_req=1;
                    external_error_code=2;
                    expected=2;
                end
                18: begin
                    begin_extract;
                    u_dut.u_free.free_count_d=MEM_DEPTH;
                    expected=5;
                end
                19: begin
                    begin_extract;
                    u_dut.u_response.reserved_d=0;
                    expected=5;
                end
            endcase
            #2;
            check(error_code==expected && error_valid && !cycle_allow,"pre-edge minimum fault");
            check(!insert_ready && !extract_ready && !commit_fire,"no acceptance or commit");
            check(!u_dut.u_free.reserve_fire && !u_dut.u_free.ram_write_en,"pre-edge RAM inhibit");
            check(!u_dut.u_epoch.insert_commit && !u_dut.u_epoch.extract_commit &&
                  !u_dut.u_response.push && !u_dut.u_response.reserve,"all domains inhibited");
            snapshot;
            tick;
            check(fault && fault_code==expected,"sticky first code");
            unchanged;
            release u_dut.u_free.ram_read_valid;
            external_error_code=1;commit_req=0;insert_val=1;extract_req=1;
            repeat(3) tick;
            check(fault_code==expected && !insert_ready && !extract_ready,"first code preserved");
            unchanged;
            // A previously committed response survives even damaged credits.
            check(extract_val && extract_payload===saved_response,"old response preserved");
            extract_out_ready=1;tick;
            check(rsp_count==saved_count-1 && !extract_val,"old response drains after fault");
            check(free_count==saved_free && queue_level==saved_level,"response pop never frees node");
            fault_cases=fault_cases+1;
        end
    end

    // External halt at every insertion phase cancels all further mutation.
    for(id=21;id<=24;id=id+1) begin
        initialize;seed_state;begin_insert;
        repeat(id-21) tick;
        if(id==24) begin
            commit_req=1;
        end
        halt=1;snapshot;tick;unchanged;
        check(!fault && !cycle_allow && !commit_fire,"halt suppresses without inventing fault");
        extract_out_ready=1;tick;
        check(!extract_val,"halt still permits old response drain");
        cancel_cases=cancel_cases+1;
    end
    // Reset with pending insertion or reserved response starts complete reinit.
    initialize;seed_state;begin_insert;initialize;
    check(!extract_val && alloc_reserved==0 && rsp_reserved==0,"reset insert cancellation");
    cancel_cases=cancel_cases+1;
    seed_state;begin_extract;initialize;
    check(!extract_val && alloc_reserved==0 && rsp_reserved==0,"reset extract cancellation");
    cancel_cases=cancel_cases+1;
    $display("PASS tb_wfq_resource_faults ptr=%0d depth=%0d faults=%0d cancellations=%0d checks=%0d",
             PTR_WIDTH,MEM_DEPTH,fault_cases,cancel_cases,checks);
    $finish;
end
initial begin
    #100000000;
    $display("FAIL resource faults watchdog");
    $finish;
end
endmodule
