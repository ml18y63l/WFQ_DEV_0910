// Full-depth FREE test including maximum legal capacity and address zero.
`timescale 1ns/1ps
module tb_wfq_free_slot_stack;
parameter integer PTR_WIDTH=16;
parameter integer MEM_DEPTH=65536;
`include "wfq_clog2.vh"
localparam integer A=wfq_clog2(MEM_DEPTH);
localparam integer C=wfq_clog2(MEM_DEPTH+1);
reg clk,rstn,init_done,init_guard,init_write_en,halt,update_allow;
reg [A-1:0] init_write_addr;
reg [PTR_WIDTH-1:0] init_write_data,release_ptr;
reg reserve_req,reserve_context,insert_commit_req,extract_commit_req;
wire alloc_valid,alloc_context;
wire [PTR_WIDTH-1:0] alloc_ptr;
wire [C-1:0] free_count,alloc_reserved,queue_level;
wire [3:0] error_code;
integer i,checks;
wfq_free_slot_stack #(.PTR_WIDTH(PTR_WIDTH),.MEM_DEPTH(MEM_DEPTH)) u_dut (
    .clk(clk),.rstn(rstn),.init_done(init_done),.init_guard(init_guard),
    .init_write_en(init_write_en),.init_write_addr(init_write_addr),
    .init_write_data(init_write_data),.halt(halt),.update_allow(update_allow),
    .reserve_req(reserve_req),.reserve_context(reserve_context),
    .insert_commit_req(insert_commit_req),.extract_commit_req(extract_commit_req),
    .release_ptr(release_ptr),.alloc_valid(alloc_valid),.alloc_context(alloc_context),
    .alloc_ptr(alloc_ptr),.free_count(free_count),.alloc_reserved(alloc_reserved),
    .queue_level(queue_level),.error_code(error_code)
);
task check;
    input ok;
    input [511:0] reason;
    begin
        checks=checks+1;
        if(ok!==1'b1) begin
            $display("FAIL FREE ptr=%0d depth=%0d i=%0d reason=%0s code=%0d",
                     PTR_WIDTH,MEM_DEPTH,i,reason,error_code);
            $finish;
        end
    end
endtask
task tick;
    begin
        #4;clk=1;#1;#4;clk=0;
    end
endtask
initial begin
    clk=0;rstn=0;init_done=0;init_guard=0;init_write_en=0;init_write_addr=0;
    init_write_data=0;halt=0;update_allow=1;reserve_req=0;reserve_context=0;
    insert_commit_req=0;extract_commit_req=0;release_ptr=0;checks=0;
    #2;rstn=1;
    for(i=0;i<MEM_DEPTH;i=i+1) begin
        init_write_en=1;init_write_addr=i;init_write_data=i;tick;
    end
    init_write_en=0;init_guard=1;tick;init_guard=0;init_done=1;#1;
    check(free_count==MEM_DEPTH && queue_level==0,"guard full count");
    for(i=0;i<MEM_DEPTH;i=i+1) begin
        reserve_req=1;reserve_context=i%2;#1;
        check(error_code==0,"reserve legal");tick;
        reserve_req=0;#1;
        check(alloc_valid && alloc_ptr==MEM_DEPTH-1-i,"full allocation pointer coverage");
        check(alloc_context==i%2,"read context");
        check(free_count==MEM_DEPTH-1-i && alloc_reserved==1 && queue_level==i,"reservation");
        insert_commit_req=1;#1;check(error_code==0,"insert commit");tick;
        insert_commit_req=0;#1;
        check(alloc_reserved==0 && queue_level==i+1,"commit accounting");
    end
    check(free_count==0 && queue_level==MEM_DEPTH && alloc_ptr==0,"all slots usable");
    reserve_req=1;#1;check(error_code==5 && !u_dut.reserve_fire,"empty stack read suppressed");
    tick;reserve_req=0;#1;check(free_count==0,"bad reserve did not wrap");
    for(i=0;i<MEM_DEPTH;i=i+1) begin
        extract_commit_req=1;release_ptr=i;#1;check(error_code==0,"release legal");tick;
        check(free_count==i+1 && queue_level==MEM_DEPTH-1-i,"release accounting");
    end
    extract_commit_req=1;#1;
    check(error_code==5 && !u_dut.ram_write_en,"full stack index must not truncate");
    tick;extract_commit_req=0;#1;
    check(free_count==MEM_DEPTH && queue_level==0,"full stack maintained");
    for(i=0;i<MEM_DEPTH;i=i+1) begin
        check(u_dut.u_ram.mem_d[i]==i,"FREE full memory image");
    end
    $display("PASS tb_wfq_free_slot_stack ptr=%0d depth=%0d checks=%0d",PTR_WIDTH,MEM_DEPTH,checks);
    $finish;
end
endmodule
