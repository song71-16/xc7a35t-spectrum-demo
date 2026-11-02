`timescale 1ns/1ps
package ethernet_pkg;
    localparam [47:0] BOARD_MAC=48'h020000003501;
    localparam [31:0] BOARD_IP=32'hc0a80a02, HOST_IP=32'hc0a80a01;
    localparam [15:0] IMAGE_PORT=16'd50000, CONTROL_PORT=16'd50001;
    function automatic [31:0] crc32_byte(input [31:0] crc,input [7:0] data);
        reg [31:0] c; integer i;
        begin c=crc ^ data;for(i=0;i<8;i=i+1)c=c[0] ? (c>>1)^32'hedb88320 : c>>1;crc32_byte=c;end
    endfunction
    function automatic [15:0] crc16_byte(input [15:0] crc,input [7:0] data);
        reg [15:0] c; integer i;
        begin c=crc^{data,8'b0};for(i=0;i<8;i=i+1)c=c[15] ? (c<<1)^16'h1021 : c<<1;crc16_byte=c;end
    endfunction
    function automatic [15:0] folded(input [31:0] value);
        reg [16:0] s;
        begin s=value[15:0]+{1'b0,value[31:16]};s={1'b0,s[15:0]}+s[16];folded=s[15:0];end
    endfunction
    function automatic [7:0] envelope_byte(input [5:0] n,input [7:0] kind,
        input [31:0] session_id,frame_id,source_id,input [15:0] epoch,packet_index,payload_length);
        reg [255:0] header;
        begin
            header={32'h52474531,8'd1,kind,16'd32,session_id,frame_id,source_id,
                    epoch,packet_index,(kind==1 ? 16'd1280 : 16'd1),payload_length,16'd1024,16'd600};
            envelope_byte=header[255-n*8 -: 8];
        end
    endfunction
endpackage
