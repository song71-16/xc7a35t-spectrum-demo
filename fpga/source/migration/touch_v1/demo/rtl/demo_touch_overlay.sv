`timescale 1ns/1ps
`include "demo_touch_ui_defs.vh"
// Existing plots/HUD retained. Bottom two text rows replace the SOURCE caption.
// Exact current phase step + Q15 + epoch in hex; rounded Hz explicitly labelled.
// Current values are independent of the older frame epoch in the existing HUD.
module demo_touch_overlay #(parameter integer CLOCK_HZ=100000000)(
    input wire pixel_clk,rst,frame_start,feedback_valid,
    input wire [84:0] feedback,
    input wire in_de,input wire [10:0] x,input wire [9:0] y,
    input wire [23:0] in_rgb,output reg [23:0] out_rgb
);
    wire [31:0] phase=feedback[84:53];
    wire [15:0] amplitude=feedback[52:37],epoch=feedback[36:21];
    wire [2:0] action=feedback[20:18];
    wire [7:0] result_status=feedback[17:10];
    wire [3:0] notice=feedback[9:6];
    wire available=feedback[5],busy=feedback[4],armed=feedback[3];
    wire fault=feedback[2],exhausted=feedback[1],presets_ready=feedback[0];
    reg [39:0] hz_digits,bcd;
    reg [31:0] binary;
    reg [5:0] step;
    reg converting,numbers_ready;
    reg [84:0] shown;
    reg shown_valid;
    wire [63:0] frequency_product=phase*64'(CLOCK_HZ);
    reg [39:0] adjusted;
    always @* begin
        adjusted=bcd;
        for(integer k=0;k<10;k=k+1)
            if(bcd[k*4+:4]>=5)adjusted[k*4+:4]=bcd[k*4+:4]+4'd3;
    end
    // feedback updates on frame_start NBA. Begin next clock, finish in porch.
    reg start_q;
    always @(posedge pixel_clk)begin
        if(rst)begin shown<=0;shown_valid<=0;start_q<=0;hz_digits<=0;bcd<=0;binary<=0;step<=0;converting<=0;numbers_ready<=0;end
        else begin
            start_q<=frame_start;
            if(start_q)begin
                shown<=feedback;shown_valid<=feedback_valid;numbers_ready<=0;
                binary<=(frequency_product+64'h80000000)>>32;bcd<=0;step<=0;converting<=1;
            end else if(converting)begin
                bcd<={adjusted[38:0],binary[31]};binary<={binary[30:0],1'b0};
                if(step==31)begin hz_digits<={adjusted[38:0],binary[31]};converting<=0;numbers_ready<=1;end
                else step<=step+1'b1;
            end
        end
    end
    function [7:0] letter(input [511:0] text,input integer length,input integer index);
        begin letter=(index>=0 && index<length) ? text[(length-1-index)*8+:8] : 8'd32;end
    endfunction
    function [7:0] hexchar(input [3:0] value);
        begin hexchar=value<10 ? 8'd48+value : 8'd55+value;end
    endfunction
    integer col,index,button,left;
    reg [7:0] character;
    reg [2:0] row,glyph_col;
    wire [4:0] glyph;
    status_font font(.character(character),.row(row),.pixels(glyph));
    reg [23:0] background,ink;
    reg enabled,border,lit;
    always @* begin
        col=x>>3;character=32;row=y[2:0];glyph_col=x[2:0];index=0;
        button=0;left=0;enabled=0;border=0;background=24'h0b1220;ink=24'he2e8f0;
        // Two 8px rows: current authority and touch outcome are text, not color alone.
        if(y>=536 && y<544)begin
            if(!shown_valid || !numbers_ready)character=letter("CURRENT UNKNOWN",15,col-8);
            else if(col>=8 && col<18)character=letter("CUR HZ RND",10,col-8);
            else if(col>=19 && col<29)character=8'd48+hz_digits[(28-col)*4+:4];
            else if(col>=30 && col<36)character=letter("STEP X",6,col-30);
            else if(col>=36 && col<44)character=hexchar(shown[53+(43-col)*4+:4]);
            else if(col>=45 && col<50)character=letter("Q15 X",5,col-45);
            else if(col>=50 && col<54)character=hexchar(shown[37+(53-col)*4+:4]);
            else if(col>=55 && col<60)character=letter("EPO X",5,col-55);
            else if(col>=60 && col<64)character=hexchar(shown[21+(63-col)*4+:4]);
        end
        if(y>=548 && y<556)begin
            row=y-548;
            if(col>=8 && col<22)begin
                if(!shown_valid || !shown[5])character=letter("UNAVAILABLE",11,col-8);
                else if(shown[2])character=letter("PROTOCOL FAULT",14,col-8);
                else if(shown[1])character=letter("ID EXHAUSTED",12,col-8);
                else character=letter(shown[3] ? "TOUCH READY" : "RELEASE TO ARM",shown[3] ? 11 : 14,col-8);
            end
            if(col>=24 && col<43)case(shown[20:18])
                `DEMO_ACTION_PENDING:character=letter("LAST LOCAL PENDING",18,col-24);
                `DEMO_ACTION_APPLIED:character=letter("LAST LOCAL APPLIED",18,col-24);
                `DEMO_ACTION_FAILED:character=letter("LAST LOCAL FAILED",17,col-24);
                `DEMO_ACTION_UNKNOWN:character=letter("LAST LOCAL UNKNOWN",18,col-24);
                default:character=letter("LAST LOCAL IDLE",15,col-24);
            endcase
            if(col>=45 && col<49)character=letter("RC X",4,col-45);
            if(col>=49 && col<51)character=hexchar(shown[10+(50-col)*4+:4]);
            if(col>=53 && col<59)character=letter("NOTE X",6,col-53);
            if(col==59)character=hexchar(shown[9:6]);
            if(col>=62 && col<81)character=letter("FRAME EPOCH AT RIGHT",19,col-62);
            if(col>=85 && col<96 && !shown[0])character=letter("PRESETS OFF",11,col-85);
        end
        if(y>=`DEMO_BUTTON_Y0 && y<=`DEMO_BUTTON_Y1)begin
            if(x>=`DEMO_FREQ1_X0 && x<=`DEMO_FREQ1_X1)begin button=1;left=`DEMO_FREQ1_X0;end
            else if(x>=`DEMO_FREQ2_X0 && x<=`DEMO_FREQ2_X1)begin button=2;left=`DEMO_FREQ2_X0;end
            else if(x>=`DEMO_FREQ3_X0 && x<=`DEMO_FREQ3_X1)begin button=3;left=`DEMO_FREQ3_X0;end
            else if(x>=`DEMO_DOWN_X0 && x<=`DEMO_DOWN_X1)begin button=4;left=`DEMO_DOWN_X0;end
            else if(x>=`DEMO_UP_X0 && x<=`DEMO_UP_X1)begin button=5;left=`DEMO_UP_X0;end
            enabled=shown_valid && shown[5] && !shown[4] && shown[3] && !shown[2] && !shown[1] && (button>3 || shown[0]);
            background=enabled ? 24'h15374b : 24'h17202d;ink=enabled ? 24'he2e8f0 : 24'h94a3b8;
            border=x==left || x==left+143 || y==`DEMO_BUTTON_Y0 || y==`DEMO_BUTTON_Y1;
            index=(x-left-16)>>4;glyph_col=(x-left-16)>>1;row=(y-572)>>1;
            if(y>=572 && y<586 && x>=left+16)case(button)
                1:character=letter("PRESET1",7,index);
                2:character=letter("PRESET2",7,index);
                3:character=letter("PRESET3",7,index);
                4:character=letter("AMP -",5,index);
                5:character=letter("AMP +",5,index);
                default:character=32;
            endcase
        end
        lit=glyph_col<5 && row<7 && glyph[4-glyph_col];
        out_rgb=in_rgb;
        if(y>=536 && y<560 && x<832)out_rgb=lit ? ink : 24'h0b1220;
        if(y>=560 && y<600 && x<832)out_rgb=button==0 ? 24'h0b1220 : (border ? ink : (lit ? ink : background));
        if(!in_de || rst)out_rgb=0;
    end
endmodule
