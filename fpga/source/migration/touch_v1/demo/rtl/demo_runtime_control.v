// Demo-only derivative of frozen rtl/proto/runtime_control.v at 0cb39cf.
// Full-system reset restores defaults; local IDs are monotonic within that reset session.
`timescale 1ns/1ps
`include "protocol_defs.vh"
module demo_runtime_control #(
    parameter integer FFT_N=512,FIR_TAPS=31,DATA_WIDTH=16,SAMPLE_RATE_HZ=100000000,
    parameter integer SYNC_PAYLOAD_READ=0
)(
    input wire clk,input wire rst,input wire safe_commit,
    // Local requests share the PC candidate/validation/commit path.
    // op 0: absolute phase increment A; 1/2: unsigned amplitude A +/- argument.
    input wire local_valid, input wire [1:0] local_op,
    input wire [31:0] local_argument, input wire [63:0] local_id,
    output wire local_ready, output reg local_done, input wire local_take,
    output reg [7:0] local_status, output reg [63:0] local_result_id,
    output reg [31:0] local_result_step, output reg [15:0] local_result_amplitude,
    output reg [15:0] local_result_epoch,
    input wire packet_valid,input wire [7:0] packet_type,
    input wire [15:0] packet_length,
    output reg [10:0] payload_addr,input wire [7:0] payload_data,
    output reg packet_release,
    output wire run_enable,output wire dual_enable,
    output wire [31:0] phase_inc_a,output wire [31:0] phase_inc_b,
    output wire [15:0] amplitude_a,output wire [15:0] amplitude_b,
    output wire [7:0] trigger_fps,output wire time_source,output wire [2:0] time_stride,
    output reg [15:0] config_epoch,
    output reg response_valid,output reg [15:0] response_length,
    output reg [15:0] response_epoch,
    input wire [10:0] response_addr,output reg [7:0] response_data,
    input wire response_release
);
    localparam IDLE=0,PIPE=15,H0=1,H1=2,H2=3,H3=4,E0=5,E1=6,E2=7,E3=8,E4=9,E5=10,CHECK=11,WAIT_SAFE=12,RESPONSE=13,RELEASE=14;
    localparam LOCAL_PREP=16, LOCAL_RESULT=17;
    reg [4:0] state;
    reg local_active, prefer_local;
    reg [1:0] local_operation;
    reg [31:0] local_value;
    reg [63:0] last_local_id;
    reg local_identity_ok;
    // A held local result blocks only another local request, not PC commands.
    assign local_ready=!rst && state==IDLE && !local_done && (!packet_valid || prefer_local);
    reg [31:0] current[0:14],candidate[0:14];
    wire signed [33:0] local_amplitude_next=$signed({2'b00,current[3]}) +
        (local_operation==2 ? -$signed({2'b00,local_value}) : $signed({2'b00,local_value}));
    reg [15:0] addresses[0:31];
    reg [31:0] values[0:31];
    reg [15:0] transaction,entry_register;
    reg [31:0] entry_value;
    reg [7:0] opcode,error_code,count,entry_index,response_count;
    reg [14:0] seen;
    integer register_index,i,j;
    reg changed;
    wire [31:0] assembled_value={payload_data,entry_value[23:0]};
    assign run_enable=current[0][0]; assign dual_enable=current[1]==2;
    assign phase_inc_a=current[2]; assign amplitude_a=current[3][15:0];
    assign phase_inc_b=current[4]; assign amplitude_b=current[5][15:0];
    assign trigger_fps=current[6][7:0]; assign time_source=current[7][0]; assign time_stride=current[8][2:0];
    function integer index_of;
        input [15:0] address;
        begin
            case(address)
                `REG_CONTROL:index_of=0; `REG_TONE_MODE:index_of=1;
                `REG_DDS_STEP_1:index_of=2; `REG_DDS_AMPLITUDE_1:index_of=3;
                `REG_DDS_STEP_2:index_of=4; `REG_DDS_AMPLITUDE_2:index_of=5;
                `REG_TRIGGER_FPS:index_of=6; `REG_TIME_SOURCE:index_of=7; `REG_TIME_STRIDE:index_of=8;
                `REG_SAMPLE_RATE_HZ:index_of=9; `REG_FFT_SIZE:index_of=10; `REG_FIR_TAPS:index_of=11;
                `REG_DATA_WIDTH:index_of=12; `REG_WINDOW:index_of=13; `REG_DECIMATION:index_of=14;
                default:index_of=-1;
            endcase
        end
    endfunction
    function [15:0] address_of;
        input integer index;
        begin
            case(index)
                0:address_of=`REG_CONTROL; 1:address_of=`REG_TONE_MODE;
                2:address_of=`REG_DDS_STEP_1; 3:address_of=`REG_DDS_AMPLITUDE_1;
                4:address_of=`REG_DDS_STEP_2; 5:address_of=`REG_DDS_AMPLITUDE_2;
                6:address_of=`REG_TRIGGER_FPS; 7:address_of=`REG_TIME_SOURCE; 8:address_of=`REG_TIME_STRIDE;
                9:address_of=`REG_SAMPLE_RATE_HZ; 10:address_of=`REG_FFT_SIZE; 11:address_of=`REG_FIR_TAPS;
                12:address_of=`REG_DATA_WIDTH; 13:address_of=`REG_WINDOW; 14:address_of=`REG_DECIMATION;
                default:address_of=16'hFFFF;
            endcase
        end
    endfunction
    function valid_value;
        input integer index;input [31:0] value;
        begin
            case(index)
                0,7:valid_value=value<=1;
                1:valid_value=value==1 || value==2;
                2,4:valid_value=!value[31];
                3,5:valid_value=value<=32767;
                6:valid_value=value>=25 && value<=30;
                8:valid_value=value==1 || value==2 || value==4;
                default:valid_value=0;
            endcase
        end
    endfunction
    always @* begin
        response_data=0;
        case(response_addr)
            0:response_data=transaction[7:0]; 1:response_data=transaction[15:8];
            2:response_data=error_code; 3:response_data=response_count;
            default:begin
                for(j=0;j<32;j=j+1) begin
                    if(response_addr==4+j*6) response_data=addresses[j][7:0];
                    if(response_addr==5+j*6) response_data=addresses[j][15:8];
                    if(response_addr==6+j*6) response_data=values[j][7:0];
                    if(response_addr==7+j*6) response_data=values[j][15:8];
                    if(response_addr==8+j*6) response_data=values[j][23:16];
                    if(response_addr==9+j*6) response_data=values[j][31:24];
                end
            end
        endcase
    end
    always @(posedge clk) begin
        if(rst) begin
            local_active<=0;prefer_local<=0;local_done<=0;local_status<=0;
            local_operation<=0;local_value<=0;last_local_id<=0;local_identity_ok<=0;
            local_result_id<=0;local_result_step<=0;local_result_amplitude<=0;local_result_epoch<=0;
            state<=IDLE;payload_addr<=0;packet_release<=0;config_epoch<=0;
            response_valid<=0;response_length<=0;response_epoch<=0;response_count<=0;
            transaction<=0;opcode<=0;error_code<=0;count<=0;entry_index<=0;
            entry_register<=0;entry_value<=0;seen<=0;register_index<=0;changed<=0;
            current[0]<=`REG_CONTROL_DEFAULT;current[1]<=`REG_TONE_MODE_DEFAULT;
            current[2]<=`REG_DDS_STEP_1_DEFAULT;current[3]<=`REG_DDS_AMPLITUDE_1_DEFAULT;
            current[4]<=`REG_DDS_STEP_2_DEFAULT;current[5]<=`REG_DDS_AMPLITUDE_2_DEFAULT;
            current[6]<=`REG_TRIGGER_FPS_DEFAULT;current[7]<=`REG_TIME_SOURCE_DEFAULT;current[8]<=`REG_TIME_STRIDE_DEFAULT;
            current[9]<=SAMPLE_RATE_HZ;current[10]<=FFT_N;current[11]<=FIR_TAPS;
            current[12]<=DATA_WIDTH;current[13]<=`REG_WINDOW_DEFAULT;current[14]<=`REG_DECIMATION_DEFAULT;
            for(i=0;i<15;i=i+1) candidate[i]<=0;
            for(i=0;i<32;i=i+1) begin addresses[i]<=0;values[i]<=0;end
        end else begin
            packet_release<=0;
            if(local_done && local_take) local_done<=0;
            case(state)
                IDLE:if(local_valid && local_ready) begin
                    prefer_local<=0;local_active<=1;local_operation<=local_op;local_value<=local_argument;
                    local_result_id<=local_id;local_identity_ok<=local_id!=0 && local_id>last_local_id;
                    if(local_id>last_local_id) last_local_id<=local_id;
                    error_code<=`PROTO_ERR_OK;changed<=0;opcode<=`PROTO_CMD_WRITE;count<=0;
                    for(i=0;i<15;i=i+1) candidate[i]<=current[i];
                    state<=LOCAL_PREP;
                end else if(packet_valid) begin
                    prefer_local<=1;local_active<=0;
                    if(packet_type!=`PROTO_TYPE_COMMAND) begin packet_release<=1;state<=RELEASE;end
                    else begin
                        payload_addr<=0;state<=PIPE;error_code<=`PROTO_ERR_OK;response_count<=0;
                        seen<=0;entry_index<=0;changed<=0;transaction<=0;
                        for(i=0;i<15;i=i+1) candidate[i]<=current[i];
                    end
                end
                // In asynchronous buffer-read mode, payload_data already
                // reflects address 0.  In synchronous mode, frame_rx loads
                // payload_data_reg on this edge, so advance the address to 1
                // while H0 samples the prefetched byte on the next edge.
                PIPE:begin
                    payload_addr<=SYNC_PAYLOAD_READ ? 1 : 0;
                    state<=H0;
                end
                H0:begin
                    if(packet_length==0) begin error_code<=`PROTO_ERR_BAD_COMMAND;state<=RESPONSE;end
                    else begin transaction[7:0]<=payload_data;payload_addr<=payload_addr+1'b1;state<=H1;end
                end
                H1:begin
                    if(packet_length<2) begin transaction<=0;error_code<=`PROTO_ERR_BAD_COMMAND;state<=RESPONSE;end
                    else begin transaction[15:8]<=payload_data;payload_addr<=payload_addr+1'b1;state<=H2;end
                end
                H2:begin
                    if(packet_length<4) begin error_code<=`PROTO_ERR_BAD_COMMAND;state<=RESPONSE;end
                    else begin opcode<=payload_data;payload_addr<=payload_addr+1'b1;state<=H3;end
                end
                H3:begin
                    count<=payload_data;
                    if(payload_data>32 || packet_length!=4+6*payload_data ||
                       (opcode!=`PROTO_CMD_READ && opcode!=`PROTO_CMD_WRITE && opcode!=`PROTO_CMD_INFO) ||
                       (opcode==`PROTO_CMD_INFO && payload_data!=0)) begin
                        error_code<=`PROTO_ERR_BAD_COMMAND;state<=RESPONSE;
                    end else if(opcode==`PROTO_CMD_INFO) begin
                        response_count<=15;
                        for(i=0;i<15;i=i+1) begin addresses[i]<=address_of(i);values[i]<=current[i];end
                        state<=RESPONSE;
                    end else if(payload_data==0) state<=opcode==`PROTO_CMD_WRITE ? WAIT_SAFE : RESPONSE;
                    else begin payload_addr<=payload_addr+1'b1;state<=E0;end
                end
                E0:begin entry_register[7:0]<=payload_data;payload_addr<=payload_addr+1'b1;state<=E1;end
                E1:begin
                    entry_register[15:8]<=payload_data;register_index<=index_of({payload_data,entry_register[7:0]});
                    payload_addr<=payload_addr+1'b1;state<=E2;
                end
                E2:begin entry_value[7:0]<=payload_data;payload_addr<=payload_addr+1'b1;state<=E3;end
                E3:begin entry_value[15:8]<=payload_data;payload_addr<=payload_addr+1'b1;state<=E4;end
                E4:begin entry_value[23:16]<=payload_data;payload_addr<=payload_addr+1'b1;state<=E5;end
                E5:begin
                    if(register_index<0) begin error_code<=`PROTO_ERR_BAD_REGISTER;state<=RESPONSE;end
                    else if(seen[register_index]) begin error_code<=`PROTO_ERR_BAD_COMMAND;state<=RESPONSE;end
                    else if(opcode==`PROTO_CMD_WRITE && register_index>=9) begin error_code<=`PROTO_ERR_READ_ONLY;state<=RESPONSE;end
                    else if(opcode==`PROTO_CMD_WRITE && !valid_value(register_index,assembled_value)) begin error_code<=`PROTO_ERR_BAD_VALUE;state<=RESPONSE;end
                    else begin
                        seen[register_index]<=1;
                        addresses[entry_index]<=entry_register;
                        values[entry_index]<=opcode==`PROTO_CMD_WRITE ? assembled_value : current[register_index];
                        if(opcode==`PROTO_CMD_WRITE) begin
                            candidate[register_index]<=assembled_value;
                            if(current[register_index]!=assembled_value) changed<=1;
                        end
                        if(entry_index+1==count) state<=CHECK;
                        else begin entry_index<=entry_index+1'b1;payload_addr<=payload_addr+1'b1;state<=E0;end
                    end
                end
                LOCAL_PREP:begin
                    if(!local_identity_ok || local_operation==3) begin
                        error_code<=`PROTO_ERR_BAD_COMMAND;state<=LOCAL_RESULT;
                    end else if(local_operation==0) begin
                        if(!valid_value(2,local_value)) begin error_code<=`PROTO_ERR_BAD_VALUE;state<=LOCAL_RESULT;end
                        else begin candidate[2]<=local_value;changed<=current[2]!=local_value;state<=CHECK;end
                    end else if(local_value==0 || local_value>32767 || local_amplitude_next<0 || local_amplitude_next>32767) begin
                        // Reject at limits, never truncate/wrap or silently clamp.
                        error_code<=`PROTO_ERR_BAD_VALUE;state<=LOCAL_RESULT;
                    end else begin
                        candidate[3]<=local_amplitude_next[31:0];changed<=current[3]!=local_amplitude_next;state<=CHECK;
                    end
                end
                LOCAL_RESULT:begin
                    local_done<=1;local_status<=error_code;local_result_epoch<=config_epoch;
                    local_result_step<=current[2];local_result_amplitude<=current[3][15:0];
                    local_active<=0;state<=IDLE;
                end
                CHECK:begin
                    if(opcode==`PROTO_CMD_WRITE && (candidate[3]+(candidate[1]==2 ? candidate[5] : 0)>32767)) begin
                        error_code<=`PROTO_ERR_BAD_VALUE;state<=local_active ? LOCAL_RESULT : RESPONSE;
                    end else begin response_count<=count;state<=opcode==`PROTO_CMD_WRITE ? WAIT_SAFE : RESPONSE;end
                end
                WAIT_SAFE:if(safe_commit) begin
                    for(i=0;i<15;i=i+1) current[i]<=candidate[i];
                    if(changed) config_epoch<=config_epoch+1'b1;
                    state<=local_active ? LOCAL_RESULT : RESPONSE;
                end
                RESPONSE:begin
                    if(!response_valid) begin
                        response_valid<=1;response_epoch<=config_epoch;
                        if(error_code!=`PROTO_ERR_OK) begin response_count<=0;response_length<=4;end
                        else response_length<=4+6*response_count;
                        packet_release<=1;
                    end else if(response_release) begin response_valid<=0;state<=IDLE;end
                end
                RELEASE:state<=IDLE;
                default:state<=IDLE;
            endcase
        end
    end
endmodule
