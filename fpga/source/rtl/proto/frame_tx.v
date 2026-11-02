`timescale 1ns/1ps
`include "protocol_defs.vh"
// Protocol-v1 packet encoder. A header and its payload are never interleaved.
// start is accepted only with start_ready; payload length must be <=2048.
module frame_tx (
    input wire clk, input wire rst,
    input wire start, output wire start_ready,
    input wire [7:0] frame_type,
    input wire [15:0] payload_length,
    input wire [31:0] frame_id,
    input wire [15:0] config_epoch,
    input wire [7:0] payload_data,
    input wire payload_valid, output wire payload_ready,
    output wire [7:0] byte_data,
    output wire byte_valid, input wire byte_ready,
    output reg done, output reg length_error
);
    localparam IDLE=0, HEADER=1, PAYLOAD=2, CRC_LO=3, CRC_HI=4;
    reg [2:0] state;
    reg [3:0] header_index;
    reg [7:0] kind;
    reg [15:0] length, epoch, payload_index, crc;
    reg [31:0] identifier;
    reg [7:0] header_data;

    function [15:0] crc_next;
        input [15:0] previous;
        input [7:0] value;
        reg [15:0] working;
        integer bit_index;
        begin
            working = previous ^ {value,8'b0};
            for (bit_index=0; bit_index<8; bit_index=bit_index+1)
                working = working[15] ? (working << 1) ^ `PROTO_CRC_POLY : working << 1;
            crc_next = working;
        end
    endfunction
    always @* begin
        case(header_index)
            0: header_data=`PROTO_SYNC_0;
            1: header_data=`PROTO_SYNC_1;
            2: header_data=`PROTO_VERSION;
            3: header_data=kind;
            4: header_data=length[7:0];
            5: header_data=length[15:8];
            6: header_data=identifier[7:0];
            7: header_data=identifier[15:8];
            8: header_data=identifier[23:16];
            9: header_data=identifier[31:24];
            10: header_data=epoch[7:0];
            11: header_data=epoch[15:8];
            default: header_data=0;
        endcase
    end
    assign start_ready = state==IDLE;
    assign byte_valid = (state==HEADER || state==CRC_LO || state==CRC_HI) ||
                        (state==PAYLOAD && payload_valid);
    assign byte_data = state==HEADER ? header_data : state==PAYLOAD ? payload_data :
                       state==CRC_LO ? crc[7:0] : crc[15:8];
    assign payload_ready = state==PAYLOAD && byte_ready;
    always @(posedge clk) begin
        if (rst) begin
            state<=IDLE; header_index<=0; kind<=0; length<=0; identifier<=0;
            epoch<=0; payload_index<=0; crc<=`PROTO_CRC_INIT; done<=0; length_error<=0;
        end else begin
            done<=0; length_error<=0;
            if (start && start_ready) begin
                if(payload_length>`PROTO_MAX_PAYLOAD) begin
                    length_error<=1;
                end else begin
                    kind<=frame_type; length<=payload_length; identifier<=frame_id;
                    epoch<=config_epoch; header_index<=0; payload_index<=0;
                    crc<=`PROTO_CRC_INIT; state<=HEADER;
                end
            end
            if (byte_valid && byte_ready) begin
                case(state)
                    HEADER: begin
                        if(header_index>=2) crc<=crc_next(crc,byte_data);
                        if(header_index==11) state<=length==0 ? CRC_LO : PAYLOAD;
                        else header_index<=header_index+1'b1;
                    end
                    PAYLOAD: begin
                        crc<=crc_next(crc,payload_data);
                        if(payload_index+1'b1==length) state<=CRC_LO;
                        else payload_index<=payload_index+1'b1;
                    end
                    CRC_LO: state<=CRC_HI;
                    CRC_HI: begin state<=IDLE; done<=1; end
                    default: state<=IDLE;
                endcase
            end
        end
    end
endmodule
