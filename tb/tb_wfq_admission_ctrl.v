// Independent RR/absolute-deadline scoreboard, including initial extract priority.
`timescale 1ns/1ps
module tb_wfq_admission_ctrl;
reg clk,rstn,init_done,init_guard,halt,update_allow,insert_val,extract_req;
reg free_available,queue_nonempty,epoch_legal,response_credit,context_available,path_ready;
wire insert_grant,extract_grant,issue_open;
wire [3:0] error_code;
integer cycle,next_issue,rr,last_fire,last_kind,checks,accepts,conflicts,seed,word,k;
reg ci,ce,ei,ee;
wfq_admission_ctrl u_dut (
    .clk(clk),.rstn(rstn),.init_done(init_done),.init_guard(init_guard),.halt(halt),
    .update_allow(update_allow),.insert_val(insert_val),.extract_req(extract_req),
    .free_available(free_available),.queue_nonempty(queue_nonempty),
    .epoch_legal(epoch_legal),.response_credit(response_credit),
    .context_available(context_available),.path_ready(path_ready),
    .insert_grant(insert_grant),.extract_grant(extract_grant),.issue_open(issue_open),
    .error_code(error_code)
);
task check;
    input ok;
    input [511:0] reason;
    begin
        checks=checks+1;
        if(ok!==1'b1) begin
            $display("FAIL admission cycle=%0d reason=%0s",cycle,reason);
            $finish;
        end
    end
endtask
task step;
    begin
        #2;
        ci=(cycle>=next_issue)&&!halt&&insert_val&&free_available&&epoch_legal;
        ce=(cycle>=next_issue)&&!halt&&extract_req&&queue_nonempty&&response_credit;
        ei=ci&&(!ce||(rr==1));
        ee=ce&&(!ci||(rr==0));
        check(insert_grant==ei && extract_grant==ee,"RR proposals");
        check(error_code==(((ei||ee)&&(!context_available||!path_ready)) ? 6:0),
              "missing context/path is schedule error");
        if(ci&&ce) begin
            conflicts=conflicts+1;
        end
        if((ei||ee)&&update_allow) begin
            check(cycle-last_fire>=5,"minimum interval");
            if(cycle<1000 && accepts!=0) begin
                check(cycle-last_fire==5 && last_kind!=ei,"continuous RR alternation");
            end
            last_kind=ei;
            last_fire=cycle;
            accepts=accepts+1;
            rr=ee;
            next_issue=cycle+5;
        end
        // Cooldown only advances when the common state gate permits it.
        else if((halt||!update_allow)&&(next_issue>cycle)) begin
            next_issue=next_issue+1;
        end
        #2;clk=1;#1;#4;clk=0;cycle=cycle+1;
    end
endtask
initial begin
    clk=0;rstn=0;init_done=0;init_guard=0;halt=0;update_allow=1;
    insert_val=1;extract_req=1;free_available=1;queue_nonempty=1;epoch_legal=1;
    response_credit=1;context_available=1;path_ready=1;
    cycle=0;next_issue=0;rr=0;last_fire=-100;last_kind=-1;checks=0;
    accepts=0;conflicts=0;seed=89217;
    #2;rstn=1;init_guard=1;
    #2;clk=1;#1;clk=0;init_guard=0;init_done=1;#2;
    check(extract_grant && !insert_grant,"reset conflict favors extract");
    for(k=0;k<1000;k=k+1) begin
        step;
    end
    check(accepts==200,"aggregate f/5 and each class f/10");
    for(k=0;k<5000;k=k+1) begin
        word=$random(seed)&32'h7fffffff;
        insert_val=word[0];extract_req=word[1];
        free_available=word[2];queue_nonempty=word[3];
        epoch_legal=word[4];response_credit=word[5];
        context_available=word[6];path_ready=word[7];
        halt=word[8]&&word[9];
        update_allow=context_available&&path_ready;
        step;
    end
    $display("PASS tb_wfq_admission_ctrl accepts=%0d conflicts=%0d checks=%0d",accepts,conflicts,checks);
    $finish;
end
endmodule
