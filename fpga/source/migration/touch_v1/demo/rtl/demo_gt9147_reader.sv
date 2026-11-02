// GT9147 programming guide: coordinate status, complete read then clear.
// Conditional profile only. No undocumented firmware ordering is assumed.
// Same dri_clk domain as demo_touch_i2c. Reset BOTH modules together.
module demo_gt9147_reader #(
    parameter bit PROFILE_CONFIGURED=0,
    parameter bit PROFILE_GT911=0,
    parameter [15:0] FW_EXACT=16'h0000,
    parameter integer RAW_WIDTH=1024,
    parameter integer RAW_HEIGHT=600,
    parameter bit SWAP_XY=0,
    parameter integer POLL_CYCLES=500,
    parameter integer TIMEOUT_CYCLES=10000
)(
    input wire clk, rst_n, bringup_ready, recover,
    output wire [6:0] slave_addr,
    output reg i2c_exec,
    output reg i2c_rh_wl,
    output wire bit_ctrl,
    output reg [15:0] i2c_addr,
    output wire [7:0] i2c_data_w,
    output reg [7:0] reg_num,
    input wire [7:0] i2c_data_r,
    input wire once_byte_done, i2c_done, ack,
    output wire available,
    output reg fault,
    output reg [3:0] fault_code,
    output reg inflight,
    output reg report_valid,
    input wire report_ready,
    output reg [3:0] report_count,
    output reg [15:0] report_x, report_y,
    output reg [31:0] product_id,
    output reg [15:0] firmware, raw_width, raw_height,
    output reg [7:0] mode_value, status_value, last_track
);
    assign slave_addr=7'h14;
    assign bit_ctrl=1'b1;
    assign i2c_data_w=8'd0; // Only write permitted: clear 0x814e.
    localparam [3:0] BOOT=0, ISSUE=1, WAIT_TX=2, GAP=3, PROCESS=4,
                     POLL=5, HOLD=6, FAULT=7;
    localparam [3:0] ID=0, FW=1, RES=2, MODE_INIT=3, MODE_POLL=4,
                     STATUS=5, POINT_LO=6, POINT_HI=7, MODE_CHECK=8, CLEAR=9;
    reg [3:0] state, command;
    reg identified;
    reg [1:0] quiet;
    reg [31:0] age, poll_age;
    reg [2:0] byte_count, point_index;
    reg [31:0] rx_data, first_half;
    reg [3:0] staged_count;
    reg [15:0] staged_x, staged_y;
    wire [15:0] point_x=first_half[23:8];
    wire [15:0] point_y={rx_data[7:0],first_half[31:24]};
    wire [3:0] count_with_pulse={1'b0,byte_count}+(once_byte_done ? 4'd1 : 4'd0);
    reg [31:0] rx_with_pulse;
    always @* begin
        rx_with_pulse=rx_data;
        if(once_byte_done && byte_count<4)
            rx_with_pulse[8*byte_count +: 8]=i2c_data_r;
    end

    // This gate also protects a same-edge downstream take. It never depends
    // on report_ready; the owned report itself is retained even when invalid.
    reg [3:0] error_now;
    always @* begin
        error_now=0;
        if(state>FAULT || command>CLEAR) error_now=10;
        else if(!inflight && (i2c_done || once_byte_done)) error_now=4;
        else if(inflight && once_byte_done && byte_count>=reg_num) error_now=2;
        else if(inflight && i2c_done && ack) error_now=1;
        else if(inflight && i2c_done && count_with_pulse!=reg_num) error_now=2;
        else if(inflight && !i2c_done && age>=TIMEOUT_CYCLES-1) error_now=3;
        else if(state!=BOOT && state!=FAULT && !bringup_ready) error_now=5;
        else if(state==PROCESS) begin
            if(PROFILE_GT911 && command==RES) begin
                if(!PROFILE_CONFIGURED || product_id!=32'h00313139 || firmware!=FW_EXACT ||
                   rx_data[15:0]!=RAW_WIDTH || rx_data[31:16]!=RAW_HEIGHT) error_now=6;
            end else if(command==MODE_INIT) begin
                if(rx_data[7:0]!=0) error_now=7;
                else if(!PROFILE_CONFIGURED || product_id!=32'h37343139 ||
                        firmware!=FW_EXACT || raw_width!=RAW_WIDTH || raw_height!=RAW_HEIGHT)
                    error_now=6;
            end else if((command==MODE_POLL || command==MODE_CHECK) && rx_data[7:0]!=0)
                error_now=7;
            else if(command==STATUS && rx_data[7] && (rx_data[6:4]!=0 || rx_data[3:0]>5))
                error_now=8;
            else if(command==POINT_HI && ((!PROFILE_GT911 && first_half[7:0]==32) || point_x>=RAW_WIDTH || point_y>=RAW_HEIGHT))
                error_now=9;
        end
    end
    assign available=identified && bringup_ready && !fault && error_now==0;

    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            state<=BOOT;command<=ID;identified<=0;quiet<=0;age<=0;poll_age<=0;
            byte_count<=0;point_index<=0;rx_data<=0;first_half<=0;
            staged_count<=0;staged_x<=0;staged_y<=0;
            i2c_exec<=0;i2c_rh_wl<=1;i2c_addr<=0;reg_num<=1;
            fault<=0;fault_code<=0;inflight<=0;
            report_valid<=0;report_count<=0;report_x<=0;report_y<=0;
            product_id<=0;firmware<=0;raw_width<=0;raw_height<=0;
            mode_value<=0;status_value<=0;last_track<=0;
        end else begin
            i2c_exec<=0;
            // Consumer may discard a held report while unavailable. Never
            // silently withdraw the only copy following a successful clear.
            if(report_valid && report_ready) report_valid<=0;
            if(fault || error_now!=0) begin
                state<=FAULT;identified<=0;fault<=1;
                if(!fault) fault_code<=error_now;
                if(inflight && i2c_done) inflight<=0;
                // An unreturned transaction retains ownership indefinitely.
                // Recovery does not reset/cancel the low-level I2C engine.
                if(fault && recover && !inflight && !report_valid &&
                   bringup_ready && !i2c_done && !once_byte_done) begin
                    state<=BOOT;command<=ID;quiet<=0;fault<=0;fault_code<=0;
                end
            end else begin
                case(state)
                    BOOT: begin
                        if(!bringup_ready) quiet<=0;
                        else if(quiet==1) begin quiet<=0;command<=ID;state<=ISSUE;end
                        else quiet<=quiet+1'b1;
                    end
                    ISSUE: begin
                        i2c_rh_wl<=command!=CLEAR;
                        case(command)
                            ID:begin i2c_addr<=16'h8140;reg_num<=4;end
                            FW:begin i2c_addr<=16'h8144;reg_num<=2;end
                            RES:begin i2c_addr<=16'h8146;reg_num<=4;end
                            MODE_INIT,MODE_POLL,MODE_CHECK:begin i2c_addr<=16'h81a8;reg_num<=1;end
                            STATUS,CLEAR:begin i2c_addr<=16'h814e;reg_num<=1;end
                            POINT_LO:begin i2c_addr<=16'h814f+({13'd0,point_index}<<3);reg_num<=4;end
                            POINT_HI:begin i2c_addr<=16'h8153+({13'd0,point_index}<<3);reg_num<=4;end
                            default:begin i2c_addr<=0;reg_num<=0;end
                        endcase
                        i2c_exec<=1;inflight<=1;byte_count<=0;rx_data<=0;age<=0;state<=WAIT_TX;
                    end
                    WAIT_TX: begin
                        if(once_byte_done) begin
                            byte_count<=byte_count+1'b1;
                            if(i2c_rh_wl) rx_data<=rx_with_pulse;
                        end
                        if(i2c_done) begin
                            inflight<=0;quiet<=0;state<=GAP;
                        end else age<=age+1'b1;
                    end
                    GAP: begin
                        if(quiet==1) begin quiet<=0;state<=PROCESS;end
                        else quiet<=quiet+1'b1;
                    end
                    PROCESS: begin
                        state<=ISSUE;
                        case(command)
                            ID:begin product_id<=rx_data;command<=FW;end
                            FW:begin firmware<=rx_data[15:0];command<=RES;end
                            RES:begin raw_width<=rx_data[15:0];raw_height<=rx_data[31:16];
                                command<=PROFILE_GT911 ? STATUS : MODE_INIT;
                                if(PROFILE_GT911) identified<=1;
                            end
                            MODE_INIT:begin mode_value<=rx_data[7:0];identified<=1;command<=MODE_POLL;end
                            MODE_POLL:begin mode_value<=rx_data[7:0];command<=STATUS;end
                            STATUS:begin
                                status_value<=rx_data[7:0];
                                if(!rx_data[7]) begin poll_age<=0;state<=POLL;end
                                else begin
                                    staged_count<=rx_data[3:0];staged_x<=0;staged_y<=0;point_index<=0;
                                    command<=rx_data[3:0]==0 ? (PROFILE_GT911 ? CLEAR : MODE_CHECK) : POINT_LO;
                                end
                            end
                            POINT_LO:begin first_half<=rx_data;command<=POINT_HI;end
                            POINT_HI:begin
                                last_track<=first_half[7:0];
                                if(staged_count==1) begin
                                    staged_x<=SWAP_XY ? point_y : point_x;
                                    staged_y<=SWAP_XY ? point_x : point_y;
                                end
                                if(point_index+1==staged_count) command<=PROFILE_GT911 ? CLEAR : MODE_CHECK;
                                else begin point_index<=point_index+1'b1;command<=POINT_LO;end
                            end
                            MODE_CHECK:begin mode_value<=rx_data[7:0];command<=CLEAR;end
                            CLEAR:begin
                                report_count<=staged_count;report_x<=staged_x;report_y<=staged_y;
                                report_valid<=1;state<=HOLD;
                            end
                            default:begin state<=FAULT;fault<=1;fault_code<=10;identified<=0;end
                        endcase
                    end
                    POLL: begin
                        if(poll_age==POLL_CYCLES-1) begin command<=PROFILE_GT911 ? STATUS : MODE_POLL;state<=ISSUE;end
                        else poll_age<=poll_age+1'b1;
                    end
                    HOLD: begin
                        if(report_valid && report_ready) begin poll_age<=0;state<=POLL;end
                    end
                    default:begin state<=FAULT;fault<=1;fault_code<=10;identified<=0;end
                endcase
            end
            // Preserve the raw failing diagnostic as well as its fault code.
            if(state==PROCESS) begin
                if(command==MODE_INIT || command==MODE_POLL || command==MODE_CHECK) mode_value<=rx_data[7:0];
                if(command==STATUS) status_value<=rx_data[7:0];
                if(command==POINT_HI) last_track<=first_half[7:0];
            end
        end
    end
    initial begin
        if(RAW_WIDTH<1 || RAW_WIDTH>65535 || RAW_HEIGHT<1 || RAW_HEIGHT>65535 ||
           POLL_CYCLES<1 || TIMEOUT_CYCLES<2)
            $fatal(1,"GT_READER_ILLEGAL_PARAMETERS");
    end
endmodule
