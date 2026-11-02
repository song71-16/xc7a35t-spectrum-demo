// DRAFT_UNVERIFIED dual-TIME derivative of migration/touch_v1/rtl/spectrum_status_overlay.sv.
`timescale 1ns/1ps
// Zero extra pixel latency: render text into the existing final I/O register.
module demo_dualtime_status(
    input wire pixel_clk,rst,frame_start,front_valid,
    input wire [31:0] front_frame_id,
    input wire [15:0] front_epoch,
    input wire [511:0] front_status,
    input wire in_de,
    input wire [10:0] x,
    input wire [9:0] y,
    input wire [23:0] in_rgb,
    output wire [23:0] out_rgb
);
    wire ready,shown_valid,peak_valid,peak_negative,noise_negative,filtered;
    wire [15:0] flags;
    wire [439:0] decimal_values;
    status_numbers numbers(.clk(pixel_clk),.rst(rst),.start(frame_start),.valid(front_valid),
        .frame_id(front_frame_id),.epoch(front_epoch),.status(front_status),.*);
    function [7:0] letter(input [255:0] text,input integer length,input integer index);
        begin letter=(index>=0 && index<length) ? text[(length-1-index)*8+:8] : 8'd32;end
    endfunction
    function [7:0] decimal_char(input [39:0] value,input integer index);
        reg leading;
        begin
            leading=1;
            for(integer k=9;k>=0;k=k-1) if(k>9-index && value[k*4+:4]!=0) leading=0;
            decimal_char=32;
            if(index>=0 && index<10) begin
                if(index==9 || !leading || value[(9-index)*4+:4]!=0)
                    decimal_char=8'd48+value[(9-index)*4+:4];
            end
        end
    endfunction
    function [7:0] db_char(input [39:0] value,input neg,input integer index);
        begin
            db_char=32;
            case(index)
                2:db_char=neg ? 8'd45 : 8'd43;
                3:db_char=value[19:16]!=0 ? 8'd48+value[19:16] : 8'd32;
                4:db_char=value[19:12]!=0 ? 8'd48+value[15:12] : 8'd32;
                5:db_char=8'd48+value[11:8];
                6:db_char=8'd46;
                7:db_char=8'd48+value[7:4];
                8:db_char=8'd48+value[3:0];
            endcase
        end
    endfunction
    reg [7:0] character;
    reg [2:0] glyph_row;
    wire [2:0] glyph_col=x[3:1];
    wire [4:0] glyph_bits;
    status_font font(.character(character),.row(glyph_row),.pixels(glyph_bits));
    integer col,line_no,field,index;
    reg [39:0] selected;
    reg [3:0] nibble;
    reg [23:0] ink;
    always @* begin
        character=32;glyph_row=y[3:1];ink=24'hcbd5e1;
        col=x>>4;line_no=y>>4;field=-1;index=col-53;selected=0;nibble=0;
        if(col>=4 && col<52) begin
            case(line_no)
                1:begin character=letter("FPGA SIGNAL ANALYZER",20,col-4);ink=24'he2e8f0;end
                3:begin
                    if(!shown_valid || !ready) character=letter("TIME / WAITING FOR DATA",23,col-4);
                    else character=letter("TIME RAW+FIR SAME SCALE",23,col-4);
                    ink=24'h49dfac;
                end
                4:character=letter("RAW GREEN FIR ORANGE BOTH WHITE",31,col-4);
                18:character=letter("SAMPLE INDEX",12,col-4);
                19:begin character=letter("SPECTRUM / FIR DBFS",19,col-4);ink=24'h59b7ff;end
                34:if(col<10) character=letter("DC",2,col-4);
                    else if(col>=44) character=letter("NYQUIST",7,col-44);
                36:character=letter("SOURCE: INTERNAL DDS",20,col-4);
            endcase
        end
        if(col<4) begin
            ink=24'h94a3b8;
            if(y>=73 && y<87) begin character=letter("+1.0",4,col);glyph_row=(y-73)>>1;end
            if(y>=169 && y<183) begin character=letter(" 0.0",4,col);glyph_row=(y-169)>>1;end
            if(y>=265 && y<279) begin character=letter("-1.0",4,col);glyph_row=(y-265)>>1;end
            if(y>=329 && y<343) begin character=letter("   0",4,col);glyph_row=(y-329)>>1;end
            if(y>=376 && y<390) begin character=letter(" -32",4,col);glyph_row=(y-376)>>1;end
            if(y>=424 && y<438) begin character=letter(" -64",4,col);glyph_row=(y-424)>>1;end
            if(y>=472 && y<486) begin character=letter(" -96",4,col);glyph_row=(y-472)>>1;end
            if(y>=520 && y<534) begin character=letter("-128",4,col);glyph_row=(y-520)>>1;end
        end
        if(col>=53 && col<64) begin
            case(line_no)
                1:character=letter("FRAME",5,index);
                2:field=0;
                4:character=letter("EPOCH",5,index);
                5:field=1;
                7:character=letter("FFT SIZE",8,index);
                8:field=2;
                10:character=letter("FS (HZ)",7,index);
                11:field=3;
                13:character=letter("DECIMATION",10,index);
                14:field=4;
                16:character=letter("STRIDE",6,index);
                17:field=5;
                19:character=letter("PEAK (HZ)",9,index);
                20:field=6;
                22:character=letter("PEAK DBFS",9,index);
                23:field=7;
                25:character=letter("NOISE DBFS",10,index);
                26:field=8;
                28:character=letter("PROC (CLK)",10,index);
                29:field=9;
                31:character=letter("UART DROP",9,index);
                32:field=10;
                34:character=letter("FLAGS HEX",9,index);
                35:begin
                    if(!shown_valid || !ready) character=letter("----",4,index);
                    else if(index<4) begin nibble=flags[(3-index)*4+:4];character=nibble<10 ? 8'd48+nibble : 8'd55+nibble;end
                end
            endcase
            if(field>=0) begin
                selected=decimal_values[field*40+:40];ink=24'he2e8f0;
                if(!shown_valid || !ready || ((field==6 || field==7) && !peak_valid))
                    character=letter("----------",10,index);
                else if(field==7 || field==8) character=db_char(selected,field==7 ? peak_negative : noise_negative,index);
                else character=decimal_char(selected,index);
            end
        end
    end
    wire lit=glyph_col<5 && glyph_row<7 && glyph_bits[4-glyph_col];
    assign out_rgb=(!in_de || rst) ? 24'd0 : lit ? ink : in_rgb;
endmodule
