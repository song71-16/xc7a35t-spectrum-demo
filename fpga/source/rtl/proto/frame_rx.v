`timescale 1ns/1ps
`include "protocol_defs.vh"
// One bounded packet buffer. Unverified payload is never visible as valid.
module frame_rx #(
    parameter integer CLOCK_HZ=100000000,
    parameter integer INTER_BYTE_CYCLES=CLOCK_HZ/10,
    parameter integer SUBFRAME_CYCLES=CLOCK_HZ/4,
    parameter integer SYNC_PAYLOAD_READ=0
)(
    input wire clk, input wire rst,
    input wire [7:0] byte_data, input wire byte_valid, output wire byte_ready,
    output reg packet_valid, output reg [7:0] packet_type,
    output reg [15:0] packet_length, output reg [31:0] packet_frame_id,
    output reg [15:0] packet_epoch,
    input wire [10:0] payload_addr, output wire [7:0] payload_data,
    input wire packet_release,
    output reg crc_error, output reg header_error, output reg timeout_error
);
    localparam SYNC0=0,SYNC1=1,HEADER=2,PAYLOAD=3,CRC0=4,CRC1=5,HOLD=6;
    reg [2:0] state;
    reg [3:0] header_index;
    reg [15:0] payload_index, crc;
    reg [7:0] crc_low;
    reg [31:0] gap_cycles, total_cycles;
    reg [7:0] buffer[0:2047];
    reg [7:0] payload_data_reg;
    wire active = state!=SYNC0 && state!=HOLD;
    wire expired = active && ((gap_cycles>=INTER_BYTE_CYCLES-1) || (total_cycles>=SUBFRAME_CYCLES-1));
    assign byte_ready = state!=HOLD;
    assign payload_data = SYNC_PAYLOAD_READ ? payload_data_reg : buffer[payload_addr];
    function [15:0] crc_next;
        input [15:0] previous; input [7:0] value;
        reg [15:0] working; integer b;
        begin
            working=previous^{value,8'b0};
            for(b=0;b<8;b=b+1) working=working[15] ? (working<<1)^`PROTO_CRC_POLY : working<<1;
            crc_next=working;
        end
    endfunction
    always @(posedge clk) begin
        if(rst) begin
            state<=SYNC0; header_index<=0; payload_index<=0; crc<=`PROTO_CRC_INIT;
            crc_low<=0; gap_cycles<=0; total_cycles<=0; packet_valid<=0;
            packet_type<=0; packet_length<=0; packet_frame_id<=0; packet_epoch<=0;
            payload_data_reg<=0; crc_error<=0; header_error<=0; timeout_error<=0;
        end else begin
            payload_data_reg<=buffer[payload_addr];
            crc_error<=0; header_error<=0; timeout_error<=0;
            if(active) begin gap_cycles<=gap_cycles+1'b1; total_cycles<=total_cycles+1'b1; end
            else begin gap_cycles<=0; total_cycles<=0; end
            if(packet_release && state==HOLD) begin packet_valid<=0; state<=SYNC0; end
            if(expired) begin
                timeout_error<=1; state<=SYNC0; gap_cycles<=0; total_cycles<=0;
                // The first byte following a stale fragment can itself begin sync.
                if(byte_valid && byte_data==`PROTO_SYNC_0) state<=SYNC1;
            end else if(byte_valid && byte_ready) begin
                gap_cycles<=0;
                case(state)
                    SYNC0: if(byte_data==`PROTO_SYNC_0) begin state<=SYNC1; total_cycles<=0; end
                    SYNC1: begin
                        if(byte_data==`PROTO_SYNC_1) begin
                            state<=HEADER; header_index<=0; crc<=`PROTO_CRC_INIT;
                        end else if(byte_data!=`PROTO_SYNC_0) state<=SYNC0;
                    end
                    HEADER: begin
                        crc<=crc_next(crc,byte_data);
                        header_index<=header_index+1'b1;
                        case(header_index)
                            0: if(byte_data!=`PROTO_VERSION) begin header_error<=1; state<=byte_data==`PROTO_SYNC_0 ? SYNC1 : SYNC0; end
                            1: begin
                                packet_type<=byte_data;
                                if(byte_data!=`PROTO_TYPE_TIME && byte_data!=`PROTO_TYPE_SPECTRUM && byte_data!=`PROTO_TYPE_STATUS && byte_data!=`PROTO_TYPE_COMMAND && byte_data!=`PROTO_TYPE_RESPONSE) begin
                                    header_error<=1; state<=byte_data==`PROTO_SYNC_0 ? SYNC1 : SYNC0;
                                end
                            end
                            2: packet_length[7:0]<=byte_data;
                            3: begin
                                packet_length[15:8]<=byte_data;
                                if({byte_data,packet_length[7:0]}>`PROTO_MAX_PAYLOAD) begin
                                    header_error<=1; state<=byte_data==`PROTO_SYNC_0 ? SYNC1 : SYNC0;
                                end
                            end
                            4: packet_frame_id[7:0]<=byte_data;
                            5: packet_frame_id[15:8]<=byte_data;
                            6: packet_frame_id[23:16]<=byte_data;
                            7: packet_frame_id[31:24]<=byte_data;
                            8: packet_epoch[7:0]<=byte_data;
                            9: begin
                                packet_epoch[15:8]<=byte_data; payload_index<=0;
                                state<=packet_length==0 ? CRC0 : PAYLOAD;
                            end
                        endcase
                    end
                    PAYLOAD: begin
                        buffer[payload_index[10:0]]<=byte_data;
                        crc<=crc_next(crc,byte_data);
                        if(payload_index+1'b1==packet_length) state<=CRC0;
                        else payload_index<=payload_index+1'b1;
                    end
                    CRC0: begin crc_low<=byte_data; state<=CRC1; end
                    CRC1: begin
                        if({byte_data,crc_low}==crc) begin packet_valid<=1; state<=HOLD; end
                        else begin crc_error<=1; state<=byte_data==`PROTO_SYNC_0 ? SYNC1 : SYNC0; end
                    end
                    default: state<=SYNC0;
                endcase
            end
        end
    end
endmodule
