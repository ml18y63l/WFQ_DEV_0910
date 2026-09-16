// FIFO scoreboard checks registered latency, conservative credit and fault drain.
`timescale 1ns/1ps
module tb_wfq_response_fifo;
parameter integer FLOW_ID_WIDTH=9;
localparam integer W=28+FLOW_ID_WIDTH;
reg clk,rstn,init_done,init_guard,update_allow,reserve_req,enqueue_req,out_ready;
reg [W-1:0] enqueue_payload;
wire out_valid,credit_available;
wire [W-1:0] out_payload;
wire [1:0] rsp_count,rsp_reserved;
wire [3:0] error_code;
reg [W-1:0] model [0:50000];
integer head,tail,reserved,k,checks,seed,word,push_pop,denials;
reg push,pop,reserve,expected_error;
wfq_response_fifo #(.FLOW_ID_WIDTH(FLOW_ID_WIDTH)) u_dut (
    .clk(clk),.rstn(rstn),.init_done(init_done),.init_guard(init_guard),
    .update_allow(update_allow),.reserve_req(reserve_req),.enqueue_req(enqueue_req),
    .enqueue_payload(enqueue_payload),.out_ready(out_ready),.out_valid(out_valid),
    .out_payload(out_payload),.credit_available(credit_available),
    .rsp_count(rsp_count),.rsp_reserved(rsp_reserved),.error_code(error_code)
);
task check;
    input ok;
    input [511:0] reason;
    begin
        checks=checks+1;
        if(ok!==1'b1) begin
            $display("FAIL fifo flow=%0d k=%0d reason=%0s",FLOW_ID_WIDTH,k,reason);
            $finish;
        end
    end
endtask
task step;
    begin
        #2;
        expected_error=(reserve_req && (tail-head+reserved>=2)) ||
                       (enqueue_req && ((reserved==0)||(tail-head>=2)));
        check(error_code==(expected_error ? 5:0),"pre-edge credit fault");
        check(credit_available==((tail-head+reserved)<2),"no borrowing current pop");
        check(out_valid==(tail!=head),"registered valid");
        if(tail!=head) begin
            check(out_payload===model[head],"stable FIFO order");
        end
        pop=(tail!=head)&&out_ready;
        push=enqueue_req&&update_allow&&!expected_error;
        reserve=reserve_req&&update_allow&&!expected_error;
        if(push&&pop) begin
            push_pop=push_pop+1;
        end
        if(expected_error) begin
            denials=denials+1;
        end
        if(pop) begin
            head=head+1;
        end
        if(push) begin
            model[tail]=enqueue_payload;
            tail=tail+1;
            reserved=reserved-1;
        end
        if(reserve) begin
            reserved=reserved+1;
        end
        #2;clk=1;#1;
        check(rsp_count==tail-head && rsp_reserved==reserved,"counts after edge");
        check(out_valid==(tail!=head),"valid immediately after production");
        if(tail!=head) begin
            check(out_payload===model[head],"payload after push/pop");
        end
        #4;clk=0;
    end
endtask
initial begin
    clk=0;rstn=0;init_done=0;init_guard=0;update_allow=1;
    reserve_req=0;enqueue_req=0;out_ready=0;enqueue_payload=0;
    head=0;tail=0;reserved=0;checks=0;seed=16431;push_pop=0;denials=0;k=0;
    #2;rstn=1;init_guard=1;
    #2;clk=1;#1;clk=0;init_guard=0;init_done=1;
    // Empty FIFO: accept/reserve E0, produce E1, earliest consume E2.
    reserve_req=1;out_ready=1;step;
    check(head==0 && tail==0 && reserved==1,"E0 reservation only");
    reserve_req=0;enqueue_req=1;enqueue_payload={16'hffff,12'habc,{FLOW_ID_WIDTH{1'b1}}};step;
    check(head==0 && tail==1,"E1 cannot consume newly produced word");
    enqueue_req=0;step;
    check(head==1 && tail==1,"E2 earliest consumption");
    for(k=0;k<20000;k=k+1) begin
        word=$random(seed)&32'h7fffffff;
        reserve_req=(word%4)==0;
        enqueue_req=((word/4)%3)==0;
        out_ready=((word/16)%4)!=0;
        update_allow=((word/64)%8)!=0;
        enqueue_payload={word[15:0],word[11:0],{FLOW_ID_WIDTH{1'b1}}};
        step;
    end
    // Stop production: old payloads drain even when all state updates are denied.
    reserve_req=0;enqueue_req=0;update_allow=0;out_ready=1;
    repeat(4) step;
    check(head==tail,"fault drain");
    check(push_pop>100 && denials>100,"simultaneous push/pop and denial coverage");
    // Reset drops outstanding reservations and payloads.
    rstn=0;#2;
    check(rsp_count==0 && rsp_reserved==0 && !out_valid,"reset cancellation");
    $display("PASS tb_wfq_response_fifo flow=%0d checks=%0d simultaneous=%0d denials=%0d",
             FLOW_ID_WIDTH,checks,push_pop,denials);
    $finish;
end
endmodule
