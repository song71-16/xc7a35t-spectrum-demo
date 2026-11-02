`timescale 1ns/1ps
// Complete payload ownership is acquired before start; no mid-packet backpressure.
module eth_mac_tx(input wire clk,rst,start,input wire [1:0] kind,
    input wire [47:0] destination,input wire [15:0] port,payload_length,payload_sum,
    output wire [10:0] read_addr,input wire [7:0] read_data,
    output reg busy=0,done=0,output reg tx_en=0,output reg [7:0] tx_data=0);
    import ethernet_pkg::*;
    reg [2:0] state=0;reg [10:0] n=0;reg [1:0] kind_q=0;
    reg [47:0] dest_q=0;reg [15:0] port_q=0,len_q=0,ip_checksum=0,udp_checksum=0;
    reg [31:0] crc=32'hffffffff;
    reg [15:0] payload_sum_q=0;
    reg [31:0] ip_sum_q=0,udp_sum_a=0,udp_sum_b=0,udp_sum_q=0;
    wire [31:0] address_sum={16'd0,BOARD_IP[31:16]}+BOARD_IP[15:0]+HOST_IP[31:16]+HOST_IP[15:0];
    wire [15:0] udp_complement=~folded(udp_sum_q);
    wire [10:0] head_length=kind_q==1 ? 14 : (kind_q==2 ? 34:42);
    wire [10:0] raw_length=head_length+len_q;
    wire [10:0] wire_length=raw_length<60 ? 60:raw_length;
    wire [15:0] ip_len_q=len_q+(kind_q==0 ? 28:20);
    wire [15:0] udp_len_q=len_q+8;
    wire [111:0] ethernet_header={dest_q,BOARD_MAC,(kind_q==1 ? 16'h0806:16'h0800)};
    wire [159:0] ip_header={8'h45,8'h00,ip_len_q,16'd0,16'h4000,8'd64,
        (kind_q==2 ? 8'd1:8'd17),ip_checksum,BOARD_IP,HOST_IP};
    wire [63:0] udp_header={port_q,port_q,udp_len_q,udp_checksum};
    reg [7:0] frame_byte,byte_q=0;
    reg [10:0] last_byte=0;
    wire [10:0] byte_index=n+1'b1;
    reg [10:0] payload_addr=0;
    assign read_addr=payload_addr;
    always @* begin
        frame_byte=0;
        if(byte_index<14)frame_byte=ethernet_header[111-byte_index*8 -: 8];
        else if(kind_q!=1 && byte_index<34)frame_byte=ip_header[159-(byte_index-14)*8 -: 8];
        else if(kind_q==0 && byte_index<42)frame_byte=udp_header[63-(byte_index-34)*8 -: 8];
        else if(byte_index<raw_length)frame_byte=read_data;
    end
    always @(posedge clk)begin
        done<=0;tx_en<=0;
        if(rst)begin state<=0;busy<=0;n<=0;crc<=32'hffffffff;tx_data<=0;end
        else case(state)
            0:if(start)begin
                busy<=1;kind_q<=kind;dest_q<=destination;port_q<=port;len_q<=payload_length;
                payload_sum_q<=payload_sum;payload_addr<=0;
                n<=0;state<=1;crc<=32'hffffffff;
            end
            1:begin tx_en<=1;tx_data<=n==7 ? 8'hd5:8'h55;
                // Checksums are prepared during the eight preamble/SFD clocks.
                // Each clock has one bounded addition stage, with no wire gaps.
                if(n==0)begin
                    last_byte<=wire_length-1'b1;
                    ip_sum_q<=32'h4500+ip_len_q+16'h4000+(kind_q==2 ? 16'h4001:16'h4011)+address_sum;
                    udp_sum_a<=address_sum+17+{udp_len_q,1'b0};
                    udp_sum_b<={port_q,1'b0}+{16'd0,payload_sum_q};
                end
                if(n==1)begin ip_checksum<=~folded(ip_sum_q);udp_sum_q<=udp_sum_a+udp_sum_b;end
                if(n==2)udp_checksum<=udp_complement==0 ? 16'hffff:udp_complement;
                if(n==7)begin byte_q<=dest_q[47:40];n<=0;state<=2;end else n<=n+1'b1;end
            2:begin tx_en<=1;tx_data<=byte_q;crc<=crc32_byte(crc,byte_q);byte_q<=frame_byte;
                if(byte_index>=head_length)payload_addr<=payload_addr+1'b1;
                if(n==last_byte)begin n<=0;state<=3;end else n<=n+1'b1;end
            3:begin tx_en<=1;tx_data<=~(crc>>(n*8));
                if(n==3)begin n<=0;state<=4;end else n<=n+1'b1;end
            4:if(n==11)begin busy<=0;done<=1;state<=0;end else n<=n+1'b1;
            default:state<=0;
        endcase
    end
endmodule
