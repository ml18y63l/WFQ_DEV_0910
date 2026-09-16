// End-to-end stable sorted-array model, full logical list and metadata scoreboard.
`timescale 1ns/1ps
module tb_wfq_tag_sort_engine;
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

parameter integer RANDOM_CYCLES=15000;
parameter integer SEED=12345;
integer cycle,checks,accepts,commits,responses,gap5,raw_hits,overlaps,contexts2;
integer seed,k,j,t,word,init_edges,epoch_input,target,last_accept,next_issue,rr,sequence;
integer nf,nr,nq,rh,rt,rs;
integer stack_model [0:MEM_DEPTH-1];
integer q_epoch [0:MEM_DEPTH-1];
reg [11:0] q_tag [0:MEM_DEPTH-1];
reg [FLOW_ID_WIDTH-1:0] q_flow [0:MEM_DEPTH-1];
integer q_ptr [0:MEM_DEPTH-1];
reg [W-1:0] rsp_model [0:200000];
integer ref_rc [0:8191];
reg [L-1:0] ref_tt [0:8191];
reg [15:0] ref_l1 [0:1];
reg [15:0] ref_l2 [0:31];
reg [15:0] ref_l3 [0:511];
reg slot_seen [0:MEM_DEPTH-1];
reg cv [0:1];
reg ct [0:1];
reg cc [0:1];
integer ca [0:1];
integer cp [0:1];
integer ce [0:1];
reg [11:0] ctag [0:1];
reg [FLOW_ID_WIDTH-1:0] cf [0:1];
integer ckey [0:1];
integer cprev [0:1];
integer csucc [0:1];
integer csame [0:1];
integer cprevtag [0:1];
integer paths [0:3];
integer due,patch,selected,work,z,idx,pos,b0,b1,first0,first1,last0,last1,key,ptr,path;
reg ci,cx,ei,ee,pop;
reg [1:0] wb,pre_valid;
reg [L-1:0] link_value,expected_link;
reg [W-1:0] expected_payload;
reg [L-1:0] raw_expected;
reg raw_now;
integer last_changed_key;

task fail;
    input [1023:0] reason;
    begin
        $display("FAIL top ptr=%0d depth=%0d seed=%0d cycle=%0d reason=%0s fault=%0d event=%0d list=%0d meta=%0d ctx=%0d",
                 PTR_WIDTH,MEM_DEPTH,SEED,cycle,reason,fault_code,
                 u_dut.u_resource.error_code,u_dut.list_error,u_dut.metadata_error,u_dut.context_error);
        $display("list checks boundary/cache/insert/extract/epoch/schedule/ptr=%b%b%b%b%b%b%b phases=%0d/%0d ctxvalid=%b",
                 u_dut.u_list.boundary_bad,u_dut.u_list.cache_bad,u_dut.u_list.insertion_bad,
                 u_dut.u_list.extraction_bad,u_dut.u_list.epoch_bad,u_dut.u_list.schedule_bad,
                 u_dut.u_list.pointer_bad,u_dut.u_list.phase_d,u_dut.u_metadata.phase_d,u_dut.context_valid);
        $finish;
    end
endtask

task check;
    input ok;
    input [1023:0] reason;
    begin
        checks=checks+1;
        if(ok!==1'b1) begin
            fail(reason);
        end
    end
endtask

function [L-1:0] node_link;
    input integer p;
    begin
        node_link=(p<0) ? {L{1'b0}} : {1'b1,p[PTR_WIDTH-1:0]};
    end
endfunction

function [L-1:0] logical_next;
    input integer p;
    reg [L-1:0] result;
    begin
        result=u_dut.u_list.u_next.mem_d[p];
        if(u_dut.u_list.pending_valid_d[0] && u_dut.u_list.pending_insert_d[0] &&
           u_dut.u_list.pending0_d[P_LSB+PTR_WIDTH] &&
           (u_dut.u_list.pending0_d[P_LSB +: PTR_WIDTH]==p)) begin
            result={1'b1,u_dut.u_list.pending0_d[N_LSB +: PTR_WIDTH]};
        end
        if(u_dut.u_list.pending_valid_d[1] && u_dut.u_list.pending_insert_d[1] &&
           u_dut.u_list.pending1_d[P_LSB+PTR_WIDTH] &&
           (u_dut.u_list.pending1_d[P_LSB +: PTR_WIDTH]==p)) begin
            result={1'b1,u_dut.u_list.pending1_d[N_LSB +: PTR_WIDTH]};
        end
        logical_next=result;
    end
endfunction

task check_metadata;
    input full_scan;
    integer m;
    begin
        for(m=0;m<2;m=m+1) begin
            check(u_dut.u_metadata.l1_flat[m*16 +: 16]===ref_l1[m],"all root words");
        end
        for(m=0;m<32;m=m+1) begin
            check(u_dut.u_metadata.l2_flat[m*16 +: 16]===ref_l2[m],"all parent words");
        end
        if(full_scan) begin
            for(m=0;m<512;m=m+1) begin
                check(u_dut.u_metadata.u_leaf.mem_d[m]===ref_l3[m],"full L3 image");
            end
            for(m=0;m<8192;m=m+1) begin
                check(u_dut.u_metadata.u_rc.u_ram.mem_d[m]===ref_rc[m][C-1:0],"full RC image");
                check(u_dut.u_metadata.u_tt.u_ram.mem_d[m]===ref_tt[m],"full TT image");
            end
        end
        else if(last_changed_key>=0) begin
            check(u_dut.u_metadata.u_leaf.mem_d[last_changed_key/16]===ref_l3[last_changed_key/16],
                  "changed L3 word");
            check(u_dut.u_metadata.u_rc.u_ram.mem_d[last_changed_key]===
                  ref_rc[last_changed_key][C-1:0],"changed RC");
            check(u_dut.u_metadata.u_tt.u_ram.mem_d[last_changed_key]===ref_tt[last_changed_key],
                  "changed TT");
        end
    end
endtask

task check_list;
    integer m,n,b,key_idx,bank_count0,bank_count1,f0,f1,l0,l1;
    reg [L-1:0] actual_next;
    begin
        bank_count0=0;bank_count1=0;f0=-1;f1=-1;l0=-1;l1=-1;
        check(u_dut.u_list.head_d===node_link((nq==0)?-1:q_ptr[0]),"global head");
        check(u_dut.u_list.tail_d===node_link((nq==0)?-1:q_ptr[nq-1]),"global tail");
        check(u_dut.u_list.cache_valid_d== (nq!=0),"head cache valid");
        if(nq!=0) begin
            check(u_dut.head_payload==={q_epoch[0][15:0],q_tag[0],q_flow[0]},"head payload");
            check(u_dut.u_list.head_next_d===node_link((nq==1)?-1:q_ptr[1]),"head logical next");
            check(u_dut.base_epoch==q_epoch[0][15:0],"oldest logical epoch");
        end
        for(m=0;m<nq;m=m+1) begin
            check(u_dut.u_list.u_data.mem_d[q_ptr[m]]==={q_epoch[m][15:0],q_tag[m],q_flow[m]},
                  "all live DATA including stable duplicate order");
            actual_next=logical_next(q_ptr[m]);
            check(actual_next===node_link((m==nq-1)?-1:q_ptr[m+1]),"logical NEXT with pending overlay");
            if((q_epoch[m]%2)==0) begin
                if(f0<0) begin
                    f0=m;
                end
                l0=m;bank_count0=bank_count0+1;
            end
            else begin
                if(f1<0) begin
                    f1=m;
                end
                l1=m;bank_count1=bank_count1+1;
            end
        end
        check(u_dut.bank0_count==bank_count0 && u_dut.bank1_count==bank_count1,"bank count sum");
        check(u_dut.u_resource.u_epoch.bank_valid==={bank_count1!=0,bank_count0!=0},"bank validity");
        check(u_dut.u_list.bank0_head_d===node_link((f0<0)?-1:q_ptr[f0]),"bank zero head");
        check(u_dut.u_list.bank0_tail_d===node_link((l0<0)?-1:q_ptr[l0]),"bank zero tail");
        check(u_dut.u_list.bank1_head_d===node_link((f1<0)?-1:q_ptr[f1]),"bank one head");
        check(u_dut.u_list.bank1_tail_d===node_link((l1<0)?-1:q_ptr[l1]),"bank one tail");
        if(f0>=0) begin
            check(u_dut.bank0_epoch==q_epoch[f0][15:0] &&
                  u_dut.u_list.bank0_min_d==q_tag[f0] && u_dut.u_list.bank0_max_d==q_tag[l0],"bank zero limits");
        end
        if(f1>=0) begin
            check(u_dut.bank1_epoch==q_epoch[f1][15:0] &&
                  u_dut.u_list.bank1_min_d==q_tag[f1] && u_dut.u_list.bank1_max_d==q_tag[l1],"bank one limits");
        end
    end
endtask

task step;
    integer h;
    begin
        insert_epoch=epoch_input;
        #2;
        check(!fault && u_dut.u_resource.error_code==0,"legal traffic must not fault");
        due=-1;patch=-1;wb=0;pre_valid={cv[1],cv[0]};
        for(h=0;h<2;h=h+1) begin
            if(cv[h]) begin
                if(cycle==ca[h]+(ct[h]?4:1)) begin
                    check(due<0,"one logical commit per edge");
                    due=h;
                end
                if(ct[h] && cycle==ca[h]+5) begin
                    patch=h;
                end
                if(cycle==ca[h]+(ct[h]?6:2)) begin
                    wb[h]=1;
                end
                if(ct[h] && cycle==ca[h]+1) begin
                    check(u_dut.alloc_valid && u_dut.alloc_context==h && u_dut.alloc_ptr==cp[h],"E1 FREE return");
                end
                if(ct[h] && cycle==ca[h]+3) begin
                    check(u_dut.pred_valid && u_dut.pred_context==h,"E3 predecessor phase");
                    check(u_dut.pred_found==(csame[h]>=0),"same-bank predecessor found");
                    if(csame[h]>=0) begin
                        check(u_dut.pred_ptr==csame[h] && u_dut.pred_tag==cprevtag[h],"same-bank max <= query");
                    end
                    check(u_dut.u_list.selected_pred===node_link(cprev[h]),"cross-epoch global predecessor");
                    if(csame[h]<0) begin
                        path=0;
                    end
                    else if(cprevtag[h]/16==ctag[h]/16) begin
                        path=1;
                    end
                    else if(cprevtag[h]/256==ctag[h]/256) begin
                        path=2;
                    end
                    else begin
                        path=3;
                    end
                    paths[path]=paths[path]+1;
                    check(u_dut.u_metadata.pred_path==path,"A/B/C path");
                end
            end
        end
        check(u_dut.commit_req==(due>=0),"commit deadline");
        check(u_dut.patch_req==(patch>=0),"patch deadline, including no-predecessor inserts");
        check(u_dut.wb_due===wb,"fixed WB lifetime");
        if(due>=0) begin
            check(u_dut.commit_context==due && u_dut.commit_is_insert==ct[due],"commit context and type");
            check(u_dut.u_metadata.rc_write_en && u_dut.u_metadata.rc_write_key==ckey[due],
                  "RC writes only the committed key");
            check(u_dut.u_metadata.tt_write_en===(ct[due] || ref_rc[ckey[due]]==1),
                  "TT tail update/last-reference invalidation schedule");
            if(u_dut.u_metadata.tt_write_en) begin
                check(u_dut.u_metadata.tt_write_key==ckey[due],"TT write address");
            end
            check(u_dut.u_metadata.leaf_write_en===(ct[due] ? ref_rc[ckey[due]]==0 : ref_rc[ckey[due]]==1),
                  "exact leaf write only on reference transition");
            if(u_dut.u_metadata.leaf_write_en) begin
                check(u_dut.u_metadata.leaf_addr==ckey[due]/16,"exact leaf write address");
            end
        end
        if(patch>=0) begin
            check(u_dut.patch_context==patch,"patch context");
        end
        ci=insert_val && nf>0 && ((nq==0)||(epoch_input==q_epoch[0])||
            (epoch_input==q_epoch[0]+1)) && cycle>=next_issue;
        cx=extract_req && nq>0 && rt-rh+rs<2 && cycle>=next_issue;
        ei=ci&&(!cx||rr==1);
        ee=cx&&(!ci||rr==0);
        check(insert_ready===ei && extract_ready===ee,"top admission/RR/window/credit");
        check(insert_epoch_blocked===(insert_val && nq>0 &&
              epoch_input!=q_epoch[0] && epoch_input!=q_epoch[0]+1),"epoch backpressure");
        check(extract_val===(rt!=rh),"pre-edge response valid");
        if(rt!=rh) begin
            check({min_epoch_out,min_tag_out,min_tag_flow_id}===rsp_model[rh],"response order and stability");
        end
        pop=(rt!=rh)&&extract_out_ready;
        check(!(u_dut.u_metadata.leaf_read_en && u_dut.u_metadata.leaf_write_en),"true 1RW L3");
        check(u_dut.u_list.u_data.write_en===((due>=0)&&ct[due]),"DATA writes only insert commit");
        check(u_dut.u_list.next_write_en===(((due>=0)&&ct[due])||((patch>=0)&&(cprev[patch]>=0))),
              "NEXT single write schedule");
        if(due>=0 && ct[due]) begin
            check(u_dut.u_list.u_data.write_addr==cp[due] &&
                  u_dut.u_list.u_data.write_data==={ce[due][15:0],ctag[due],cf[due]},"DATA E4 direct write");
            check(u_dut.u_list.next_write_addr==cp[due] &&
                  u_dut.u_list.next_write_data===node_link(csucc[due]),"NEXT new node E4");
        end
        if(patch>=0 && cprev[patch]>=0) begin
            check(u_dut.u_list.next_write_addr==cprev[patch] &&
                  u_dut.u_list.next_write_data===node_link(cp[patch]),"NEXT predecessor E5");
        end
        raw_now=u_dut.u_list.next_read_en && u_dut.u_list.next_write_en &&
            (u_dut.u_list.next_read_addr==u_dut.u_list.next_write_addr);
        raw_expected=u_dut.u_list.next_write_data;
        if(raw_now) begin
            raw_hits=raw_hits+1;
        end
        if(due>=0 && (|wb)) begin
            overlaps=overlaps+1;
        end
        selected=cv[0]?1:0;
        if(pop) begin
            rh=rh+1;responses=responses+1;
        end
        for(h=0;h<2;h=h+1) begin
            if(wb[h]) begin
                cv[h]=0;cc[h]=0;
            end
        end
        last_changed_key=-1;
        if(due>=0) begin
            commits=commits+1;cc[due]=1;key=ckey[due];last_changed_key=key;
            if(ct[due]) begin
                pos=0;
                while(pos<nq && ((q_epoch[pos]<ce[due]) ||
                    ((q_epoch[pos]==ce[due])&&(q_tag[pos]<=ctag[due])))) begin
                    pos=pos+1;
                end
                for(h=nq;h>pos;h=h-1) begin
                    q_epoch[h]=q_epoch[h-1];q_tag[h]=q_tag[h-1];
                    q_flow[h]=q_flow[h-1];q_ptr[h]=q_ptr[h-1];
                end
                q_epoch[pos]=ce[due];q_tag[pos]=ctag[due];q_flow[pos]=cf[due];q_ptr[pos]=cp[due];
                nq=nq+1;nr=nr-1;
                ref_rc[key]=ref_rc[key]+1;
                ref_tt[key]=node_link(cp[due]);
                ref_l3[key/16][key%16]=1;
                ref_l2[key/256][(key/16)%16]=1;
                ref_l1[key/4096][(key/256)%16]=1;
            end
            else begin
                check(cp[due]==q_ptr[0],"extract the accepted stable minimum");
                rsp_model[rt]={ce[due][15:0],ctag[due],cf[due]};rt=rt+1;rs=rs-1;
                stack_model[nf]=cp[due];nf=nf+1;
                nq=nq-1;
                for(h=0;h<nq;h=h+1) begin
                    q_epoch[h]=q_epoch[h+1];q_tag[h]=q_tag[h+1];
                    q_flow[h]=q_flow[h+1];q_ptr[h]=q_ptr[h+1];
                end
                ref_rc[key]=ref_rc[key]-1;
                if(ref_rc[key]==0) begin
                    ref_tt[key]=0;
                    ref_l3[key/16][key%16]=0;
                    ref_l2[key/256][(key/16)%16]=(ref_l3[key/16]!=0);
                    ref_l1[key/4096][(key/256)%16]=(ref_l2[key/256]!=0);
                end
            end
        end
        if(ei||ee) begin
            check(cycle-last_accept>=5,"minimum accepted interval");
            if(cycle-last_accept==5) begin
                gap5=gap5+1;
            end
            check(!pre_valid[selected] && u_dut.request_context==selected,"free context selection");
            last_accept=cycle;next_issue=cycle+5;rr=ee;accepts=accepts+1;
            cv[selected]=1;ct[selected]=ei;ca[selected]=cycle;cc[selected]=0;
            if(ei) begin
                nf=nf-1;nr=nr+1;cp[selected]=stack_model[nf];
                ce[selected]=epoch_input;ctag[selected]=insert_tag;cf[selected]=insert_flow_id;
                cprev[selected]=-1;csame[selected]=-1;cprevtag[selected]=0;pos=0;
                for(h=0;h<nq;h=h+1) begin
                    if(q_epoch[h]<epoch_input ||
                       (q_epoch[h]==epoch_input && q_tag[h]<=insert_tag)) begin
                        cprev[selected]=q_ptr[h];pos=h+1;
                    end
                    if(q_epoch[h]==epoch_input && q_tag[h]<=insert_tag) begin
                        csame[selected]=q_ptr[h];cprevtag[selected]=q_tag[h];
                    end
                end
                csucc[selected]=(pos<nq)?q_ptr[pos]:-1;
            end
            else begin
                cp[selected]=q_ptr[0];ce[selected]=q_epoch[0];ctag[selected]=q_tag[0];cf[selected]=q_flow[0];
                csucc[selected]=(nq>1)?q_ptr[1]:-1;rs=rs+1;
            end
            ckey[selected]=(ce[selected]%2)*4096+ctag[selected];
        end

        #2;clk=1;#1;
        check(!fault,"post-edge fault");
        check(insert_commit===((due>=0)&&ct[due]) &&
              extract_commit===((due>=0)&&!ct[due]),"commit pulse after actual edge");
        check(queue_level==nq && u_dut.u_resource.free_count==nf &&
              u_dut.u_resource.alloc_reserved==nr,"committed/reserved capacity");
        check(nf+nr+nq==MEM_DEPTH,"capacity conservation");
        check(u_dut.context_valid==={cv[1],cv[0]} && busy===(cv[1]||cv[0]),"WB busy lifetime");
        check(u_dut.u_list.pending_valid_d==={cv[1]&&cc[1],cv[0]&&cc[0]},"descriptor lifetime");
        check(u_dut.rsp_count==rt-rh && u_dut.rsp_reserved==rs,"response counters");
        check(extract_val===(rt!=rh),"response available immediately after E1");
        if(rt!=rh) begin
            check({min_epoch_out,min_tag_out,min_tag_flow_id}===rsp_model[rh],"response payload after edge");
        end
        check(empty===(nq==0) && full===(nf==0),"empty and full definitions");
        check(idle===(!busy && rt==rh && rs==0),"idle excludes pending responses");
        if(raw_now) begin
            check(u_dut.u_list.next_read_data===raw_expected &&
                  u_dut.u_list.u_next.bypass_hit_d,"same-edge NEXT bypass captured");
        end
        if(cv[0]&&cv[1]) begin
            contexts2=contexts2+1;
        end
        if(due>=0) begin
            check_list;
            check_metadata((commits%257)==0);
        end
        if(patch>=0 && cprev[patch]>=0) begin
            check(u_dut.u_list.u_next.mem_d[cprev[patch]]===node_link(cp[patch]),
                  "E5 physical patch persisted before overlay release");
        end
        #4;clk=0;cycle=cycle+1;
    end
endtask

task wait_idle;
    input integer n;
    integer h;
    begin
        insert_val=0;extract_req=0;
        for(h=0;h<n;h=h+1) begin
            step;
        end
    end
endtask

task put;
    input integer e;
    input [11:0] tag;
    input integer flow;
    integer goal;
    begin
        epoch_input=e;insert_tag=tag;insert_flow_id=flow;insert_val=1;extract_req=0;
        goal=accepts+1;
        while(accepts<goal) begin
            step;
        end
        wait_idle(4);
    end
endtask

task take;
    integer goal;
    begin
        insert_val=0;extract_req=1;goal=accepts+1;
        while(accepts<goal) begin
            step;
        end
        wait_idle(4);
    end
endtask

task drain;
    integer watchdog;
    begin
        insert_val=0;extract_out_ready=1;watchdog=0;
        while(nq!=0 || nr!=0 || cv[0] || cv[1] || rh!=rt) begin
            extract_req=(nq!=0);
            step;watchdog=watchdog+1;
            if(watchdog>MEM_DEPTH*8+100) begin
                fail("drain timeout");
            end
        end
        wait_idle(5);check_metadata(1);
    end
endtask

initial begin
    clk=0;rstn=0;insert_val=0;extract_req=0;extract_out_ready=1;
    insert_epoch=0;insert_tag=0;insert_flow_id=0;epoch_input=0;
    cycle=0;checks=0;accepts=0;commits=0;responses=0;gap5=0;raw_hits=0;overlaps=0;contexts2=0;
    nf=MEM_DEPTH;nr=0;nq=0;rh=0;rt=0;rs=0;last_accept=-100;next_issue=0;rr=0;seed=SEED;
    last_changed_key=-1;
    for(k=0;k<MEM_DEPTH;k=k+1) begin
        stack_model[k]=k;
    end
    for(k=0;k<8192;k=k+1) begin
        ref_rc[k]=0;ref_tt[k]=0;
    end
    for(k=0;k<512;k=k+1) begin
        ref_l3[k]=0;
    end
    for(k=0;k<32;k=k+1) begin
        ref_l2[k]=0;
    end
    for(k=0;k<2;k=k+1) begin
        cv[k]=0;ct[k]=0;cc[k]=0;ca[k]=-100;ref_l1[k]=0;
    end
    for(k=0;k<4;k=k+1) begin
        paths[k]=0;
    end
    #2;rstn=1;init_edges=0;
    while(!init_done) begin
        #2;check(!insert_ready && !extract_ready && !extract_val && !busy && !idle && !full,"initialization masking");
        #2;clk=1;#1;#4;clk=0;init_edges=init_edges+1;
        if(init_edges>65540) begin
            fail("initialization timeout");
        end
    end
    check(init_edges==((MEM_DEPTH>8192)?MEM_DEPTH:8192)+3,"two reset release edges plus scan and guard");
    check_metadata(1);
    step;

    put(7,4095,1);take;drain;
    put(7,100,1);put(7,0,2);put(7,4095,3);put(7,100,4);drain;
    put(8,10,1);put(8,15,2);put(8,10,3);take;put(8,10,4);drain;
    put(9,12'h1ff,1);put(9,12'h250,2);put(9,12'h300,3);put(9,12'h240,4);drain;
    put(9,12'h210,1);put(9,12'h250,2);put(9,12'h240,3);drain;
    put(9,12'h245,1);put(9,12'h249,2);put(9,12'h247,3);drain;
    put(10,0,1);put(10,1,2);put(10,16,3);put(10,256,4);put(10,4095,5);drain;
    // F22: A->B->C, insert D after B, then E5 read and patch NEXT[B].
    put(11,10,1);put(11,20,2);put(11,30,3);put(11,25,4);take;drain;
    // F11: head cache next must be fixed before the physical patch.
    put(12,10,1);put(12,30,2);put(12,20,3);take;drain;
    // F13-F16: modulo wrap, two keys in each bank, third generation held.
    put(65535,4090,1);put(65536,0,2);put(65535,4095,3);put(65536,10,4);
    insert_val=1;epoch_input=65537;insert_tag=5;insert_flow_id=5;extract_req=1;extract_out_ready=0;
    target=accepts+3;
    while(accepts<target) begin
        step;
    end
    wait_idle(7);drain;
    // F21: an old response survives an empty queue and arbitrary new base.
    put(125,17,1);extract_out_ready=0;take;
    check(nq==0 && rt-rh==1,"empty queue with unconsumed response");
    put(999,23,2);wait_idle(8);drain;
    // Full shared capacity, first a duplicate group and then both banks.
    for(k=0;k<MEM_DEPTH;k=k+1) begin
        put(500,4095,k);
    end
    check(full && nq==MEM_DEPTH && nr==0,"default full 1024 not truncated");
    insert_val=1;epoch_input=500;insert_tag=4095;insert_flow_id=0;
    for(k=0;k<10;k=k+1) begin
        step;
    end
    extract_req=1;
    for(k=0;k<30;k=k+1) begin
        step;
    end
    wait_idle(5);drain;
    for(k=0;k<MEM_DEPTH;k=k+1) begin
        case(k%3)
            0: put(600+(k%2),1024,k);
            1: put(600+(k%2),2047,k);
            2: put(600+(k%2),4095,k);
        endcase
    end
    check(full && u_dut.bank0_count+u_dut.bank1_count==MEM_DEPTH,"shared two-bank capacity");
    drain;
    // Sustained RR and all adjacent operation combinations.
    for(k=0;k<8;k=k+1) begin
        put(700,k*100,k);
    end
    epoch_input=700;insert_val=1;extract_req=1;
    for(k=0;k<500;k=k+1) begin
        insert_tag=accepts;insert_flow_id=accepts;
        step;
    end
    wait_idle(5);drain;

    for(k=0;k<RANDOM_CYCLES;k=k+1) begin
        word=$random(seed)&32'h7fffffff;
        if(!insert_val||ei) begin
            insert_val=(word%8)<5;
            if(nq==0) begin
                epoch_input=100000+word%10000;
            end
            else begin
                case((word/512)%8)
                    0: epoch_input=q_epoch[0]+2;
                    1,2,3: epoch_input=q_epoch[0]+1;
                    default: epoch_input=q_epoch[0];
                endcase
            end
            case((word/128)%4)
                0: insert_tag=0;
                1: insert_tag=4095;
                2: insert_tag=word%32;
                default: insert_tag=word;
            endcase
            insert_flow_id=word/4096;
        end
        if(!extract_req||ee) begin
            extract_req=((word/8)%8)<6;
        end
        if(k%23==0) begin
            extract_out_ready=((word/64)%4)!=0;
        end
        step;
    end
    wait_idle(5);drain;
    check(accepts==commits && responses*2==commits,"accepted operations fully accounted");
    check(nf==MEM_DEPTH && nr==0 && idle,"all capacity and contexts returned");
    check(raw_hits>0 && overlaps>0 && contexts2>0 && gap5>100,"RAW/overlap/throughput exercised");
    for(k=0;k<4;k=k+1) begin
        check(paths[k]>0,"all predecessor paths");
    end
    for(k=0;k<MEM_DEPTH;k=k+1) begin
        slot_seen[k]=0;
    end
    for(k=0;k<MEM_DEPTH;k=k+1) begin
        ptr=u_dut.u_resource.u_free.u_ram.mem_d[k];
        check(ptr<MEM_DEPTH && !slot_seen[ptr],"FREE permutation after reuse");
        slot_seen[ptr]=1;
    end
    $display("PASS tb_wfq_tag_sort_engine ptr=%0d depth=%0d flow=%0d seed=%0d accepts=%0d responses=%0d gap5=%0d raw=%0d overlaps=%0d contexts2=%0d paths=%0d/%0d/%0d/%0d checks=%0d",
             PTR_WIDTH,MEM_DEPTH,FLOW_ID_WIDTH,SEED,accepts,responses,gap5,raw_hits,overlaps,contexts2,
             paths[0],paths[1],paths[2],paths[3],checks);
    $finish;
end
initial begin
    #100000000;
    fail("watchdog");
end
endmodule
