`timescale 1ns/1ps
module eth_image(input wire rst,pixel_clk,net_clk,net_rst,
    input wire frame_start,front_valid,de,input wire [23:0] rgb,
    input wire [31:0] source_frame,input wire [15:0] epoch,
    input wire enable,input wire [31:0] session_id,
    output wire packet_valid,input wire packet_take,packet_done,
    input wire [10:0] read_addr,output wire [7:0] read_data,
    output wire [15:0] payload_sum,output reg [31:0] capture_drops=0);
    import ethernet_pkg::*;
    reg pixel_enable=0;reg [31:0] pixel_session=0;
    wire config_ack,config_valid;wire [32:0] config_data;reg config_send=0;
    // A bundled handshake transfers session and stream state atomically.
    always @(posedge net_clk)
        if(net_rst||config_ack)config_send<=0;else config_send<=1;
    xpm_cdc_handshake #(.WIDTH(33),.DEST_SYNC_FF(3),.SRC_SYNC_FF(3),.DEST_EXT_HSK(0),.INIT_SYNC_FF(1)) config_cdc(
        .src_clk(net_clk),.src_in({enable,session_id}),.src_send(config_send),.src_rcv(config_ack),
        .dest_clk(pixel_clk),.dest_out(config_data),.dest_req(config_valid),.dest_ack(1'b0));
    always @(posedge pixel_clk)
        if(rst)begin pixel_enable<=0;pixel_session<=0;end
        else if(config_valid)begin pixel_enable<=config_data[32];pixel_session<=config_data[31:0];end
    reg alternate=0,capturing=0;reg [2:0] meta=0;reg [31:0] frame_id=0,held_session=0,held_source=0;
    reg [15:0] held_epoch=0;reg [19:0] pixels=0;
    wire [35:0] fifo_out;reg [35:0] fifo_in;reg wr_en;wire full,empty,wb,rb;
    reg pop;
    always @* begin
        wr_en=0;fifo_in=0;
        if(capturing && pixel_enable)begin
            if(meta!=0)begin
                wr_en=1;
                case(meta)
                    1:fifo_in={4'd2,held_session};
                    2:fifo_in={4'd3,frame_id};
                    3:fifo_in={4'd4,held_source};
                    4:fifo_in={4'd5,16'd0,held_epoch};
                    default:fifo_in=0;
                endcase
            end else if(de)begin wr_en=1;fifo_in={4'd1,8'd0,rgb};end
        end
    end
    always @(posedge pixel_clk)begin
        if(rst)begin alternate<=0;capturing<=0;meta<=0;frame_id<=0;pixels<=0;capture_drops<=0;end
        else begin
            if(!pixel_enable)begin capturing<=0;meta<=0;end
            if(frame_start)begin
                alternate<=!alternate;
                if(!alternate && pixel_enable && front_valid && !full && !wb)begin
                    capturing<=1;meta<=1;frame_id<=frame_id+1'b1;pixels<=0;
                    held_session<=pixel_session;held_source<=source_frame;held_epoch<=epoch;
                end
            end
            if(wr_en)begin
                if(full||wb)begin capturing<=0;meta<=0;capture_drops<=capture_drops+1'b1;end
                else if(meta!=0)meta<=(meta==4 ? 0 : meta+1'b1);
                else begin
                    pixels<=pixels+1'b1;
                    if(pixels==614399)capturing<=0;
                end
            end
        end
    end
    eth_async_fifo #(.WIDTH(36),.DEPTH(16384)) crossing(.rst(rst),.wr_clk(pixel_clk),.rd_clk(net_clk),
        .din(fifo_in),.wr_en(wr_en),.rd_en(pop),.dout(fifo_out),.full(full),.empty(empty),.wr_busy(wb),.rd_busy(rb));
    (* ram_style="distributed" *) reg [7:0] memory[0:4095];
    reg [1:0] ready=0;reg write_bank=0,read_bank=0,in_flight=0;
    reg [15:0] sums[0:1];reg [31:0] session_q=0,frame_q=0,source_q=0;
    reg [15:0] epoch_q=0,packet_index=0;reg [10:0] pos=0;reg [1:0] channel=0;
    reg [31:0] checksum=0;reg [7:0] high_byte=0;
    reg [2:0] state=0; // seek session, frame, source, epoch, header, pixels
    reg write_byte;reg [7:0] byte_value;
    assign packet_valid=ready[read_bank]&&!in_flight;
    assign read_data=memory[{read_bank,read_addr}];
    assign payload_sum=sums[read_bank];
    always @* begin
        pop=0;write_byte=0;byte_value=0;
        if(!rb && !ready[write_bank])begin
            if(state<4)pop=!empty;
            else if(state==4)begin
                write_byte=1;byte_value=envelope_byte(pos[5:0],1,session_q,frame_q,source_q,epoch_q,packet_index,1440);
            end else if(state==5 && !empty)begin
                if(fifo_out[35:32]!=1)pop=1;
                else begin
                    write_byte=1;
                    case(channel)
                        0:byte_value=fifo_out[23:16];
                        1:byte_value=fifo_out[15:8];
                        2:begin byte_value=fifo_out[7:0];pop=1;end
                        default:byte_value=0;
                    endcase
                end
            end
        end
    end
    always @(posedge net_clk)begin
        if(net_rst)begin ready<=0;write_bank<=0;read_bank<=0;in_flight<=0;state<=0;pos<=0;channel<=0;checksum<=0;end
        else begin
            if(packet_take)in_flight<=1;
            if(packet_done)begin ready[read_bank]<=0;read_bank<=!read_bank;in_flight<=0;end
            if(pop && !empty)begin
                if(fifo_out[35:32]==2)begin session_q<=fifo_out[31:0];state<=1;pos<=0;channel<=0;checksum<=0;end
                else case(state)
                    0:state<=0;
                    1:if(fifo_out[35:32]==3)begin frame_q<=fifo_out[31:0];state<=2;end else state<=0;
                    2:if(fifo_out[35:32]==4)begin source_q<=fifo_out[31:0];state<=3;end else state<=0;
                    3:if(fifo_out[35:32]==5)begin epoch_q<=fifo_out[15:0];packet_index<=0;state<=4;end else state<=0;
                    5:if(fifo_out[35:32]!=1)begin state<=0;pos<=0;channel<=0;checksum<=0;end
                    default:state<=0;
                endcase
            end
            if(state==6)begin
                ready[write_bank]<=1;sums[write_bank]<=folded(checksum);
                write_bank<=!write_bank;pos<=0;checksum<=0;channel<=0;
                packet_index<=packet_index+1'b1;state<=(packet_index==1279 ? 0 : 4);
            end
            if(write_byte)begin
                memory[{write_bank,pos}]<=byte_value;
                if(!pos[0])high_byte<=byte_value;else checksum<=checksum+{high_byte,byte_value};
                pos<=pos+1'b1;
                if(state==4 && pos==31)state<=5;
                if(state==5)channel<=(channel==2 ? 0 : channel+1'b1);
                if(pos==1471)state<=6;

            end
        end
    end
endmodule
