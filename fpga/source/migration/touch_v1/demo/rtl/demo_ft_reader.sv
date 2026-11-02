`timescale 1ns/1ps
// Conditional FT-compatible register reader, not exact controller identification.
// No configuration-data writes: only read transaction register-pointer phases.
// The five-byte burst groups count/first point; controller-side sample latching
// and actual coordinate orientation must be verified separately on the panel.
module demo_ft_reader #(
    parameter bit PROFILE_CONFIGURED=0,
    parameter [15:0] VERSION_BE_EXACT=16'h0001,
    parameter integer RAW_WIDTH=4096,RAW_HEIGHT=4096,
    parameter bit SWAP_XY=0,
    parameter integer POLL_CYCLES=5000,TIMEOUT_CYCLES=10000
)(
    input wire clk,rst_n,bringup_ready,
    output wire [6:0] slave_addr,
    output reg i2c_exec,
    output wire i2c_rh_wl,bit_ctrl,
    output reg [15:0] i2c_addr,
    output wire [7:0] i2c_data_w,
    output reg [7:0] reg_num,
    input wire [7:0] i2c_data_r,
    input wire once_byte_done,i2c_done,ack,
    output wire available,
    output reg fault,output reg [3:0] fault_code,
    output reg inflight,report_valid,input wire report_ready,
    output reg [3:0] report_count,
    output reg [15:0] report_x,report_y,version_be,
    output wire [79:0] diagnostic_state,
    output reg [39:0] raw_report
);
    assign slave_addr=7'h38;
    assign i2c_rh_wl=1'b1;
    assign bit_ctrl=1'b0;
    assign i2c_data_w=0;
    localparam [2:0] BOOT=0,ISSUE=1,WAIT_TX=2,GAP=3,PROCESS=4,HOLD=5,POLL=6,LOCKED=7;
    localparam [1:0] VERSION=0,MODE=1,POINT=2;
    reg [2:0] state,byte_count;
    reg [1:0] command,quiet;
    reg [31:0] age,poll_age;
    reg identified,first_valid_seen;
    reg [39:0] rx,rx_next;
    reg [15:0] startup_ff_count;
    reg [14:0] up_ignored_count;
    wire startup_ff=state==PROCESS && command==POINT && !first_valid_seen && rx==40'hffffffffff;
    wire [3:0] count_next={1'b0,byte_count}+(once_byte_done?4'd1:4'd0);
    wire [3:0] point_count=rx[3:0];
    wire [1:0] point_event=rx[15:14];
    wire [15:0] point_x={4'd0,rx[11:8],rx[23:16]};
    wire [15:0] point_y={4'd0,rx[27:24],rx[39:32]};
    wire point_up=state==PROCESS && command==POINT && rx[7:4]==0 && point_count==1 && point_event==1 && rx[31:28]!=15;
    assign diagnostic_state={startup_ff_count,first_valid_seen,state,command,byte_count,rx,up_ignored_count};
    reg [3:0] error_now;
    always @* begin
        rx_next=rx;
        if(once_byte_done && byte_count<5) rx_next[8*byte_count +: 8]=i2c_data_r;
        error_now=0;
        if(!inflight && (i2c_done || once_byte_done)) error_now=4;
        else if(inflight && once_byte_done && byte_count>=reg_num) error_now=2;
        else if(inflight && i2c_done && ack) error_now=1;
        else if(inflight && i2c_done && count_next!=reg_num) error_now=2;
        else if(inflight && !i2c_done && age>=TIMEOUT_CYCLES-1) error_now=3;
        else if(state!=BOOT && state!=LOCKED && !bringup_ready) error_now=5;
        else if(state==PROCESS) begin
            if(command==VERSION && {rx[7:0],rx[15:8]}!=VERSION_BE_EXACT) error_now=6;
            else if(command==MODE && rx[6:4]!=0) error_now=7;
            else if(command==POINT && !startup_ff) begin
                if(rx[7:4]!=0 || point_count>5) error_now=8;
                // Touch count is not a bound on tracking ID; 0xF is sentinel.
                else if(point_count==1 && (point_event==3 || rx[31:28]==15)) error_now=8;
                else if(point_count==1 && point_event!=1 &&
                        (point_x>=RAW_WIDTH || point_y>=RAW_HEIGHT)) error_now=9;
            end
        end
    end
    assign available=PROFILE_CONFIGURED && identified && first_valid_seen && bringup_ready && !fault && error_now==0;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            state<=BOOT;command<=VERSION;byte_count<=0;quiet<=0;age<=0;poll_age<=0;
            rx<=0;identified<=0;first_valid_seen<=0;startup_ff_count<=0;up_ignored_count<=0;i2c_exec<=0;i2c_addr<=0;reg_num<=0;
            fault<=0;fault_code<=0;inflight<=0;report_valid<=0;
            report_count<=0;report_x<=0;report_y<=0;version_be<=0;raw_report<=0;
        end else begin
            i2c_exec<=0;
            if(report_valid && report_ready) report_valid<=0;
            if(fault || error_now!=0) begin
                state<=LOCKED;fault<=1;identified<=0;
                if(!fault) fault_code<=error_now;
                if(inflight && i2c_done) inflight<=0;
                // No local retry/reset. Late done cannot replace the fault.
            end else case(state)
                BOOT: begin
                    if(!PROFILE_CONFIGURED || !bringup_ready) quiet<=0;
                    else if(quiet==1) begin quiet<=0;state<=ISSUE;command<=VERSION;end
                    else quiet<=quiet+1'b1;
                end
                ISSUE: begin
                    case(command)
                        VERSION:begin i2c_addr<=16'h00a1;reg_num<=2;end
                        MODE:begin i2c_addr<=0;reg_num<=1;end
                        POINT:begin i2c_addr<=2;reg_num<=5;end
                        default:begin i2c_addr<=0;reg_num<=0;end
                    endcase
                    rx<=0;byte_count<=0;age<=0;i2c_exec<=1;inflight<=1;state<=WAIT_TX;
                end
                WAIT_TX: begin
                    if(once_byte_done) begin rx<=rx_next;byte_count<=byte_count+1'b1;end
                    if(i2c_done) begin inflight<=0;quiet<=0;state<=GAP;end
                    else age<=age+1'b1;
                end
                GAP:if(quiet==1)begin quiet<=0;state<=PROCESS;end else quiet<=quiet+1'b1;
                PROCESS:case(command)
                    VERSION:begin version_be<={rx[7:0],rx[15:8]};command<=MODE;state<=ISSUE;end
                    MODE:begin identified<=1;command<=POINT;state<=ISSUE;end
                    POINT:begin
                        raw_report<=rx;
                        // Full-load hardware can return complete FF frames before ready.
                        // No release/report/action is synthesized from this startup value.
                        if(startup_ff) begin
                            if(startup_ff_count!=16'hffff) startup_ff_count<=startup_ff_count+1'b1;
                            poll_age<=0;state<=POLL;
                        end else if(point_up) begin
                            // Lift-up with nonzero count is not a coordinate or release.
                            // Preserve ownership until an explicit count-zero report.
                            if(up_ignored_count!=15'h7fff) up_ignored_count<=up_ignored_count+1'b1;
                            poll_age<=0;state<=POLL;
                        end else begin
                        first_valid_seen<=1;
                        // Only TD_STATUS=0 can re-arm the downstream actions.
                        report_count<=point_count;
                        report_x<=0;report_y<=0;
                        if(point_count==1 && point_event!=1) begin
                            report_x<=SWAP_XY?point_y:point_x;
                            report_y<=SWAP_XY?point_x:point_y;
                        end
                        report_valid<=1;state<=HOLD;
                        end
                    end
                    default:begin fault<=1;fault_code<=10;identified<=0;state<=LOCKED;end
                endcase
                HOLD:if(report_valid && report_ready)begin poll_age<=0;state<=POLL;end
                POLL:if(poll_age==POLL_CYCLES-1)begin command<=MODE;state<=ISSUE;end else poll_age<=poll_age+1'b1;
                default:begin fault<=1;fault_code<=10;identified<=0;state<=LOCKED;end
            endcase
            if(state==PROCESS && command==VERSION)version_be<={rx[7:0],rx[15:8]};
            if(state==PROCESS && command==POINT)raw_report<=rx;
        end
    end
    initial begin
        if(RAW_WIDTH<1 || RAW_WIDTH>4096 || RAW_HEIGHT<1 || RAW_HEIGHT>4096 ||
           POLL_CYCLES<1 || TIMEOUT_CYCLES<8)$fatal(1,"FT_READER_ILLEGAL_PARAMETERS");
    end
endmodule
