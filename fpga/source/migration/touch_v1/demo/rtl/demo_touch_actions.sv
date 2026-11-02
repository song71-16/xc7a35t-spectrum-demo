`timescale 1ns/1ps
`include "demo_touch_ui_defs.vh"
// One control-clock domain. Not a touch driver, coordinate CDC, or display.
// rst MUST be the same full-system reset as demo_runtime_control.
// Complete fresh reports only: valid=0 is NO_UPDATE, never a release.
module demo_touch_actions #(
    parameter integer OFFER_CYCLES=50000000, RESULT_CYCLES=100000000,
    parameter [31:0] AMPLITUDE_STEP=32'd1024,
    parameter [63:0] INITIAL_ID=64'd1
)(
    input wire clk,rst,
    input wire available,report_fault,report_valid,
    input wire [3:0] report_count,
    input wire [15:0] report_x,report_y,
    input wire presets_ready,
    input wire [31:0] preset_phase_0,preset_phase_1,preset_phase_2,
    output wire local_valid,input wire local_ready,
    output reg [1:0] local_op,output reg [31:0] local_argument,
    output reg [63:0] local_id,
    input wire local_done,input wire [63:0] local_result_id,
    input wire [7:0] local_status,output wire local_take,
    output wire busy,output reg armed,protocol_fault,id_exhausted,
    output reg [2:0] action_state,output reg [7:0] result_status,
    output reg [3:0] notice,output reg press_rejected
);
    // Parameter contract: 1 <= timeouts <= 2^31-1; 1 <= STEP <= 32767;
    // INITIAL_ID is nonzero (production=1). No independent in-flight reset.
    localparam [1:0] IDLE=0,OFFER=1,WAIT_RESULT=2,QUARANTINE=3;
    reg [1:0] state;
    reg [31:0] age;
    reg [63:0] next_id;
    reg [2:0] hit;
    wire coordinates_ok=report_x<16'd1024 && report_y<16'd600;
    // Availability loss cancels only an unaccepted OFFER, on its next edge.
    // If ready is also high on that edge, the REAL handshake wins and is owned.
    assign local_valid=!rst && state==OFFER && !protocol_fault && !local_done;
    assign local_take=!rst && !protocol_fault && state==WAIT_RESULT &&
                      local_done && local_result_id==local_id;
    assign busy=state!=IDLE;
    always @* begin
        hit=0;
        if(coordinates_ok && report_y>=`DEMO_BUTTON_Y0 && report_y<=`DEMO_BUTTON_Y1) begin
            if(report_x>=`DEMO_FREQ1_X0 && report_x<=`DEMO_FREQ1_X1) hit=1;
            else if(report_x>=`DEMO_FREQ2_X0 && report_x<=`DEMO_FREQ2_X1) hit=2;
            else if(report_x>=`DEMO_FREQ3_X0 && report_x<=`DEMO_FREQ3_X1) hit=3;
            else if(report_x>=`DEMO_DOWN_X0 && report_x<=`DEMO_DOWN_X1) hit=4;
            else if(report_x>=`DEMO_UP_X0 && report_x<=`DEMO_UP_X1) hit=5;
        end
    end
    always @(posedge clk) begin
        if(rst) begin
            state<=IDLE;age<=0;next_id<=INITIAL_ID;
            local_op<=0;local_argument<=0;local_id<=0;
            armed<=0;protocol_fault<=0;id_exhausted<=0;
            action_state<=`DEMO_ACTION_NONE;result_status<=0;
            notice<=`DEMO_NOTICE_NONE;press_rejected<=0;
        end else begin
            press_rejected<=0;
            if(!available || report_fault) begin
                armed<=0;notice<=`DEMO_NOTICE_UNAVAILABLE;
            end
            // A mismatched/orphan result is not consumed or repaired by release.
            // Preserve local_id and quarantine until the full-system reset.
            if(local_done && (state!=WAIT_RESULT || local_result_id!=local_id)) begin
                state<=QUARANTINE;protocol_fault<=1;armed<=0;
                action_state<=`DEMO_ACTION_UNKNOWN;notice<=`DEMO_NOTICE_PROTOCOL;
            end else if(!protocol_fault) begin
                case(state)
                    OFFER:begin
                        if(local_valid && local_ready) begin
                            state<=WAIT_RESULT;age<=0;
                            if(next_id==64'hffffffffffffffff) id_exhausted<=1;
                            else next_id<=next_id+64'd1;
                        end else if(!available || report_fault || age==OFFER_CYCLES-1) begin
                            state<=IDLE;age<=0;armed<=0;
                            action_state<=`DEMO_ACTION_FAILED;
                            notice<=(!available || report_fault) ? `DEMO_NOTICE_UNAVAILABLE : `DEMO_NOTICE_NOT_ADMITTED;
                        end else age<=age+32'd1;
                    end
                    WAIT_RESULT:begin
                        // Authoritative matching completion beats the deadline.
                        if(local_take) begin
                            state<=IDLE;age<=0;result_status<=local_status;
                            action_state<=local_status==0 ? `DEMO_ACTION_APPLIED : `DEMO_ACTION_FAILED;
                        end else if(age==RESULT_CYCLES-1) begin
                            // Notify only; do not abandon the accepted identity.
                            action_state<=`DEMO_ACTION_UNKNOWN;
                        end else age<=age+32'd1;
                    end
                    default:begin end
                endcase
                if(available && !report_fault) begin
                    // NO_UPDATE keeps the existing press/release ownership.
                    if(report_valid) begin
                        if(report_count==0) armed<=1;
                        else if(armed) begin
                            armed<=0;
                            // All first contacts consume the arm, even rejection.
                            if(report_count>5 || !coordinates_ok) begin
                                press_rejected<=1;notice<=`DEMO_NOTICE_INVALID;
                            end else if(report_count!=1) begin
                                press_rejected<=1;notice<=`DEMO_NOTICE_MULTITOUCH;
                            end else if(hit==0) begin
                                press_rejected<=1;notice<=`DEMO_NOTICE_OUTSIDE;
                            end else if(state!=IDLE) begin
                                // Includes a completion on this same edge: no hidden queue.
                                press_rejected<=1;notice<=`DEMO_NOTICE_BUSY;
                            end else if(id_exhausted) begin
                                press_rejected<=1;notice<=`DEMO_NOTICE_ID_EXHAUSTED;
                            end else if(hit<=3 && !presets_ready) begin
                                press_rejected<=1;notice<=`DEMO_NOTICE_PRESETS;
                            end else begin
                                local_id<=next_id;age<=0;state<=OFFER;
                                action_state<=`DEMO_ACTION_PENDING;result_status<=0;
                                notice<=`DEMO_NOTICE_NONE;
                                case(hit)
                                    1:begin local_op<=0;local_argument<=preset_phase_0;end
                                    2:begin local_op<=0;local_argument<=preset_phase_1;end
                                    3:begin local_op<=0;local_argument<=preset_phase_2;end
                                    4:begin local_op<=2;local_argument<=AMPLITUDE_STEP;end
                                    5:begin local_op<=1;local_argument<=AMPLITUDE_STEP;end
                                    default:begin end
                                endcase
                            end
                        end
                    end
                end
            end else begin
                armed<=0;notice<=`DEMO_NOTICE_PROTOCOL;
            end
        end
    end
endmodule
