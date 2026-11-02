// Demo-only declaration-order derivative; original Ethernet source preserved.
`timescale 1ns/1ps
module demo_eth_endpoint #(parameter integer HEARTBEAT_CYCLES=375000000)(
    input wire clk,rst,link_up,
    input wire [1:0] diagnostic_link_flags,
    input wire rx_valid,input wire [10:0] rx_length,output reg rx_release=0,
    output wire [10:0] rx_addr,input wire [7:0] rx_data,
    output wire [7:0] command_data,output wire command_valid,input wire command_ready,
    input wire [8:0] response_data,input wire response_valid,output wire response_ready,
    input wire image_valid,input wire [15:0] image_sum,input wire [7:0] image_data,
    output wire image_take,image_done,output wire [10:0] image_addr,
    output wire tx_en,output wire [7:0] tx_data,
    output wire stream_enable,output reg [31:0] session_id=0,
    output reg [31:0] rejected=0);
    import ethernet_pkg::*;
    localparam IDLE=0,HEADER=1,CHECK=2,IP_SUM=3,L4_SUM=4,L4_CHECK=5,
        APP_HEADER=6,APP_CHECK=7,CMD_CRC=8,CMD_CHECK=9,CMD_COPY=10,
        REPLY_COPY=11,REPLY_SUM=12,REPLY_COMMIT=13,ICMP_COPY=14,ICMP_FIX=15,
        ARP_COPY=16,REJECT=17,RESPONSE_COPY=18,IP_CHECK=19,REPLY_FOLD=20,IP_FOLD=21,L4_FOLD=22,ICMP_FOLD=23,APP_VALIDATE=24;
    reg [4:0] state=IDLE;
    reg [10:0] n=0,l4_length=0,inner_length=0;
    reg [7:0] header[0:41];reg [7:0] app_header[0:31];
    (* ram_style="distributed" *) reg [7:0] reply_memory[0:2047];
    (* ram_style="distributed" *) reg [7:0] command_cache[0:511];
    (* ram_style="distributed" *) reg [7:0] response_cache[0:511];
    // Register the packet RAM output before checksum/validation logic. Control
    // traffic accepts one byte every three clocks; the image TX remains 1 byte/clock.
    reg [1:0] read_phase=0;reg [10:0] rx_address_q=0,rx_next_addr;
    assign rx_addr=rx_address_q;reg [7:0] packet_byte=0,reply_sum_byte=0;
    wire reads_packet=state==HEADER||state==IP_SUM||state==L4_SUM||state==APP_HEADER||
        state==APP_CHECK||state==CMD_CRC||state==CMD_COPY||state==ICMP_COPY;
    wire needs_read=reads_packet||state==REPLY_SUM;
    wire advance=!needs_read||read_phase==2;
    always @(posedge clk)begin
        if(rst)read_phase<=0;
        else if(needs_read)begin
            if(read_phase==0)begin rx_address_q<=rx_next_addr;read_phase<=1;end
            else if(read_phase==1)begin packet_byte<=rx_data;reply_sum_byte<=reply_memory[n];read_phase<=2;end
            else if(state!=CMD_COPY||command_ready)read_phase<=0;
        end else read_phase<=0;
    end
    reg [15:0] sum_folded=0;reg app_valid=0;
    reg [31:0] sum=0;reg [7:0] high=0;
    always @(posedge clk)sum_folded<=folded(sum);
    reg [15:0] inner_crc=16'hffff;reg [7:0] crc_low=0,inner_size_low=0;reg same_command=0;
    reg active=0,streaming=0,pending=0,cache_valid=0,response_waiting=0;
    reg [31:0] last_sequence=0;reg [9:0] last_length=0,response_length=0,response_index=0;
    reg response_overflow=0;
    reg [28:0] heartbeat=0;
    reg [47:0] peer_mac=0;
    reg reply_ready=0;reg [1:0] reply_kind=0;reg [15:0] reply_length=0,reply_sum=0;
    reg [47:0] reply_mac=0;reg [7:0] envelope_kind=0;
    reg [31:0] envelope_session=0,envelope_sequence=0;
    reg [15:0] envelope_length=0;reg [7:0] simple_payload=0;
    reg reply_from_cache=0;
    wire [47:0] destination={header[0],header[1],header[2],header[3],header[4],header[5]};
    wire [47:0] source_mac={header[6],header[7],header[8],header[9],header[10],header[11]};
    wire [15:0] ether_type={header[12],header[13]},ip_length={header[16],header[17]};
    wire [31:0] source_ip={header[26],header[27],header[28],header[29]};
    wire [31:0] dest_ip={header[30],header[31],header[32],header[33]};
    wire [31:0] app_session={app_header[8],app_header[9],app_header[10],app_header[11]};
    wire [31:0] app_sequence={app_header[12],app_header[13],app_header[14],app_header[15]};
    wire [15:0] app_length={app_header[26],app_header[27]};
    wire [7:0] app_kind=app_header[5];
    wire [31:0] sequence_distance=app_sequence-last_sequence;
    wire tx_busy,tx_done;reg tx_image=0;
    wire start_tx=!tx_busy&&!tx_done&&link_up&&(reply_ready||(image_valid&&stream_enable));
    wire choose_image=!reply_ready;
    wire [10:0] tx_addr;
    assign image_addr=tx_addr;
    assign image_take=start_tx&&choose_image;
    assign image_done=tx_done&&tx_image;
    assign stream_enable=active&&streaming&&link_up;
    assign command_data=packet_byte;
    assign command_valid=state==CMD_COPY&&read_phase==2;
    assign response_ready=pending&&!response_waiting;
    eth_mac_tx transmitter(.clk(clk),.rst(rst),.start(start_tx),
        .kind(choose_image ? 2'd0:reply_kind),.destination(choose_image ? peer_mac:reply_mac),
        .port(choose_image ? IMAGE_PORT:CONTROL_PORT),.payload_length(choose_image ? 16'd1472:reply_length),
        .payload_sum(choose_image ? image_sum:reply_sum),.read_addr(tx_addr),
        .read_data(tx_image ? image_data:reply_memory[tx_addr]),.busy(tx_busy),.done(tx_done),.tx_en(tx_en),.tx_data(tx_data));
    reg [7:0] reply_byte;
    wire reply_write=advance&&(state==ARP_COPY||state==ICMP_COPY||state==REPLY_COPY||state==ICMP_FIX);
    wire [10:0] reply_write_addr=state==ICMP_FIX ? (n==0 ? 11'd2:11'd3):n;
    wire [7:0] reply_write_data=state==ICMP_FIX ? (n==0 ? ~(sum_folded>>8):~sum_folded):reply_byte;
    // One physical write port. Multiple procedural address expressions caused
    // the first candidate to expand this packet RAM into thousands of FFs/LUTs.
    always @(posedge clk)if(!rst&&reply_write)reply_memory[reply_write_addr]<=reply_write_data;
    wire [223:0] arp_reply={16'h0001,16'h0800,8'd6,8'd4,16'h0002,BOARD_MAC,BOARD_IP,source_mac,
        header[28],header[29],header[30],header[31]};
    always @* begin
        rx_next_addr=0;reply_byte=0;
        case(state)
            HEADER:rx_next_addr=n;
            IP_SUM:rx_next_addr=14+n;
            L4_SUM:rx_next_addr=34+n;
            APP_HEADER:rx_next_addr=42+n;
            CMD_CRC,CMD_CHECK,CMD_COPY:rx_next_addr=74+n;
            APP_CHECK:rx_next_addr=74;
            ICMP_COPY:begin rx_next_addr=34+n;reply_byte=(n==0||n==2||n==3) ? 0:packet_byte;end
            ARP_COPY:reply_byte=arp_reply[223-n*8 -:8];
            REPLY_COPY:begin
                if(n<32)reply_byte=envelope_byte(n[5:0],envelope_kind,envelope_session,envelope_sequence,0,0,0,envelope_length);
                else reply_byte=reply_from_cache ? response_cache[n-32]:simple_payload;
            end
            REPLY_SUM:reply_byte=reply_sum_byte;
            default:rx_next_addr=0;
        endcase
    end
    always @(posedge clk)begin
        rx_release<=0;
        if(rst)begin
            state<=IDLE;active<=0;streaming<=0;session_id<=0;heartbeat<=0;pending<=0;
            cache_valid<=0;response_waiting<=0;reply_ready<=0;response_index<=0;response_overflow<=0;
            n<=0;sum<=0;rejected<=0;last_sequence<=0;last_length<=0;tx_image<=0;
        end else begin
            if(start_tx)tx_image<=choose_image;
            if(tx_done&&!tx_image)reply_ready<=0;
            if(heartbeat!=0)heartbeat<=heartbeat-1'b1;
            else begin active<=0;streaming<=0;end
            if(!link_up)begin active<=0;streaming<=0;end
            if(response_valid&&response_ready)begin
                if(response_index<512)response_cache[response_index[8:0]]<=response_data[7:0];else response_overflow<=1;
                if(response_data[8])begin
                    response_length<=response_index+1'b1;response_index<=0;
                    pending<=0;cache_valid<=!response_overflow&&response_index<512;
                    response_waiting<=!response_overflow&&response_index<512;response_overflow<=0;
                end else if(response_index<1023)response_index<=response_index+1'b1;
            end
            if(advance)case(state)
                IDLE:if(!reply_ready)begin
                    if(response_waiting)begin
                        response_waiting<=0;envelope_kind<=7;envelope_session<=session_id;envelope_sequence<=last_sequence;
                        envelope_length<=response_length;reply_from_cache<=1;reply_kind<=0;reply_mac<=peer_mac;
                        n<=0;state<=REPLY_COPY;
                    end else if(rx_valid&&!rx_release)begin n<=0;state<=HEADER;end
                end
                HEADER:begin
                    header[n]<=packet_byte;
                    if(n==41)begin n<=0;state<=CHECK;end else n<=n+1'b1;
                end
                CHECK:begin
                    n<=0;sum<=0;
                    if(ether_type==16'h0806 && (destination==BOARD_MAC||destination==48'hffffffffffff)
                        && {header[14],header[15],header[16],header[17],header[18],header[19]}==48'h000108000604
                        && {header[20],header[21]}==1
                        && {header[28],header[29],header[30],header[31]}==HOST_IP
                        && {header[38],header[39],header[40],header[41]}==BOARD_IP)begin
                        reply_mac<=source_mac;reply_kind<=1;reply_length<=28;state<=ARP_COPY;
                    end else if(ether_type==16'h0800 && destination==BOARD_MAC && source_ip==HOST_IP && dest_ip==BOARD_IP
                        && header[14]==8'h45 && ip_length>=28 && ip_length<=1500 && ip_length+14<=rx_length
                        && ({header[20],header[21]} & 16'hbfff)==0 && header[22]!=0
                        && (header[23]==1 || header[23]==17))begin
                        l4_length<=ip_length-20;state<=IP_SUM;
                    end else state<=REJECT;
                end
                IP_SUM:begin
                    if(!n[0])high<=packet_byte;else sum<=sum+{high,packet_byte};
                    if(n==19)begin n<=0;state<=IP_FOLD;end else n<=n+1'b1;
                end
                IP_FOLD:state<=IP_CHECK;
                IP_CHECK:begin
                    if(sum_folded!=16'hffff)state<=REJECT;
                    else begin
                        n<=0;state<=L4_SUM;
                        sum<=header[23]==17 ? {16'd0,HOST_IP[31:16]}+HOST_IP[15:0]+BOARD_IP[31:16]+BOARD_IP[15:0]+17+l4_length:0;
                    end
                end
                L4_SUM:begin
                    if(!n[0])high<=packet_byte;else sum<=sum+{high,packet_byte};
                    if(n==l4_length-1)begin
                        sum<=sum+(n[0] ? {high,packet_byte}:{packet_byte,8'd0});n<=0;state<=L4_FOLD;
                    end else n<=n+1'b1;
                end
                L4_FOLD:state<=L4_CHECK;
                L4_CHECK:begin
                    if(sum_folded!=16'hffff)state<=REJECT;
                    else if(header[23]==1 && header[34]==8 && header[35]==0)begin
                        reply_mac<=source_mac;reply_kind<=2;reply_length<=l4_length;
                        n<=0;sum<=0;state<=ICMP_COPY;
                    end else if(header[23]==17 && {header[34],header[35]}==CONTROL_PORT
                        && {header[36],header[37]}==CONTROL_PORT && {header[38],header[39]}==l4_length
                        && {header[40],header[41]}!=0 && l4_length>=40 && l4_length<=552)begin
                        n<=0;state<=APP_HEADER;
                    end else state<=REJECT;
                end
                APP_HEADER:begin
                    app_header[n]<=packet_byte;
                    if(n==31)begin n<=0;state<=APP_VALIDATE;end else n<=n+1'b1;
                end
                APP_VALIDATE:begin
                    app_valid<=!({app_header[0],app_header[1],app_header[2],app_header[3],app_header[4]}!=40'h5247453101
                        || {app_header[6],app_header[7]}!=32 || app_session==0
                        || {app_header[22],app_header[23],app_header[24],app_header[25]}!=32'h00000001
                        || {app_header[28],app_header[29],app_header[30],app_header[31]}!=32'h04000258
                        || app_length+40!=l4_length || app_length>512);
                    state<=APP_CHECK;
                end
                APP_CHECK:begin
                    reply_mac<=source_mac;reply_kind<=0;reply_from_cache<=0;
                    envelope_session<=app_session;envelope_sequence<=app_sequence;
                    if(!app_valid)state<=REJECT;
                    else if(app_kind==2 && app_length==0 && !pending && !response_waiting && link_up)begin
                        if(!active || app_session!=session_id)begin
                            session_id<=app_session;streaming<=0;last_sequence<=0;cache_valid<=0;
                        end
                        active<=1;heartbeat<=HEARTBEAT_CYCLES;peer_mac<=source_mac;
                        envelope_kind<=3;envelope_length<=1;simple_payload<=1;n<=0;state<=REPLY_COPY;
                    end else if(!active || app_session!=session_id || !link_up)state<=REJECT;
                    else if((app_kind==4||app_kind==5) && app_length==1 && packet_byte<=1)begin
                        heartbeat<=HEARTBEAT_CYCLES;streaming<=packet_byte[0];
                        envelope_kind<=app_kind;envelope_length<=1;simple_payload<=packet_byte;n<=0;state<=REPLY_COPY;
                    end else if(app_kind==6 && app_length>=18 && app_sequence!=0)begin
                        inner_length<=app_length;inner_crc<=16'hffff;same_command<=app_length==last_length;
                        n<=0;state<=CMD_CRC;
                    end else state<=REJECT;
                end
                CMD_CRC:begin
                    if(n==4)inner_size_low<=packet_byte;
                    if(n>=2 && n<inner_length-2)inner_crc<=crc16_byte(inner_crc,packet_byte);
                    if(n==inner_length-2)crc_low<=packet_byte;
                    if(command_cache[n[8:0]]!=packet_byte)same_command<=0;
                    if((n==0&&packet_byte!=8'haa)||(n==1&&packet_byte!=8'h55)||(n==2&&packet_byte!=1)||(n==3&&packet_byte!=16)
                        ||(n==5&&{packet_byte,inner_size_low}+14!=inner_length)
                        ||(n==12&&packet_byte!=app_sequence[7:0])||(n==13&&packet_byte!=app_sequence[15:8])
                        ||(n==15&&(packet_byte>32 || 18+6*packet_byte!=inner_length)))state<=REJECT;
                    else if(n==inner_length-1)begin
                        if({packet_byte,crc_low}!=inner_crc)state<=REJECT;
                        else begin n<=0;state<=CMD_CHECK;end
                    end else n<=n+1'b1;
                end
                CMD_CHECK:begin
                    if(app_sequence==last_sequence)begin
                        if(!same_command)state<=REJECT;
                        else if(cache_valid)begin
                            envelope_kind<=7;envelope_length<=response_length;reply_from_cache<=1;n<=0;state<=REPLY_COPY;
                        end else begin rx_release<=1;state<=IDLE;end
                    end else if(pending || sequence_distance[31] || sequence_distance==0)state<=REJECT;
                    else begin
                        last_sequence<=app_sequence;last_length<=inner_length;pending<=1;cache_valid<=0;
                        response_index<=0;response_overflow<=0;n<=0;state<=CMD_COPY;
                    end
                end
                CMD_COPY:if(command_ready)begin
                    command_cache[n[8:0]]<=packet_byte;
                    if(n==inner_length-1)begin rx_release<=1;state<=IDLE;end else n<=n+1'b1;
                end
                ARP_COPY:begin
                    if(n==27)begin n<=0;sum<=0;state<=REPLY_SUM;end else n<=n+1'b1;
                end
                ICMP_COPY:begin
                    if(!n[0])high<=reply_byte;else sum<=sum+{high,reply_byte};
                    if(n==reply_length-1)begin sum<=sum+(n[0] ? {high,reply_byte}:{reply_byte,8'd0});n<=0;state<=ICMP_FOLD;end
                    else n<=n+1'b1;
                end
                ICMP_FOLD:state<=ICMP_FIX;
                ICMP_FIX:begin
                    if(n==0)n<=1;
                    else begin n<=0;sum<=0;state<=REPLY_SUM;end
                end
                REPLY_COPY:begin
                    reply_length<=32+envelope_length;
                    if(n==31+envelope_length)begin n<=0;sum<=0;state<=REPLY_SUM;end else n<=n+1'b1;
                end
                REPLY_SUM:begin
                    if(!n[0])high<=reply_byte;else sum<=sum+{high,reply_byte};
                    if(n==reply_length-1)begin
                        sum<=sum+(n[0] ? {high,reply_byte}:{reply_byte,8'd0});state<=REPLY_FOLD;
                    end else n<=n+1'b1;
                end
                REPLY_FOLD:begin reply_sum<=folded(sum);state<=REPLY_COMMIT;end
                REPLY_COMMIT:begin reply_ready<=1;rx_release<=1;state<=IDLE;end
                REJECT:begin rejected<=rejected+1'b1;rx_release<=1;state<=IDLE;end
                default:state<=REJECT;
            endcase
        end
    end

    reg [15:0] observed_headers=0,observed_arp=0,observed_tx=0,observed_reject=0;
    reg [31:0] observed_arp_source=0;
    reg [127:0] net_observation=0;
    always @(posedge clk) begin
      if(rst)begin
        observed_headers<=0;observed_arp<=0;observed_tx<=0;observed_reject<=0;observed_arp_source<=0;
      end else begin
        if(advance && state==CHECK)begin
          if(observed_headers!=16'hffff)observed_headers<=observed_headers+1'b1;
          if(ether_type==16'h0806)observed_arp_source<={header[28],header[29],header[30],header[31]};
        end
        if(advance && state==ARP_COPY && n==0 && observed_arp!=16'hffff)observed_arp<=observed_arp+1'b1;
        if(start_tx && !choose_image && reply_kind==1 && observed_tx!=16'hffff)observed_tx<=observed_tx+1'b1;
        if(advance && state==REJECT && observed_reject!=16'hffff)observed_reject<=observed_reject+1'b1;
      end
      net_observation<={16'hD145,rst,link_up,diagnostic_link_flags,rx_valid,reply_ready,tx_busy,active,
        3'd0,state,observed_headers,observed_arp,observed_tx,observed_reject,observed_arp_source};
    end
    touch_identity_vio network_evidence(.clk(clk),.probe_in0(net_observation));
endmodule
