// Project : wfq_tag_sort_engine
// File    : wfq_clog2.vh
// Spec    : Design_Spec_V1.2.md, sections 2 and 15.1
// Function: Module-local Verilog-2001 constant function.
// Include once inside each consuming module. Deliberately no global guard.

function integer wfq_clog2;
    input integer                                       value;
    integer                                             temp;
    begin
        temp = value - 1;
        wfq_clog2 = 0;
        while (temp > 0) begin
            temp = temp >> 1;
            wfq_clog2 = wfq_clog2 + 1;
        end
    end
endfunction
