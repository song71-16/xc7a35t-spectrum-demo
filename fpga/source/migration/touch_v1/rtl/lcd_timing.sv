// Generic scan engine. Defaults are a SIMULATION candidate, not MD0700 signoff.
// All outputs describe the current pixel; downstream pipelines must delay the
// entire bundle together. rst is synchronous to pixel_clk, active high.
module lcd_timing #(
    parameter integer H_SYNC=20, H_BACK=140, H_ACTIVE=1024, H_FRONT=160,
    parameter integer V_SYNC=3, V_BACK=20, V_ACTIVE=600, V_FRONT=12,
    parameter bit HS_ACTIVE=1'b0, VS_ACTIVE=1'b0
)(
    input wire pixel_clk, rst,
    output wire hsync, vsync, de,
    output wire [10:0] x,
    output wire [9:0] y,
    output wire frame_start, vblank_start
);
    localparam integer HT=H_SYNC+H_BACK+H_ACTIVE+H_FRONT;
    localparam integer VT=V_SYNC+V_BACK+V_ACTIVE+V_FRONT;
    localparam integer HB=H_SYNC+H_BACK, VB=V_SYNC+V_BACK;
    localparam integer HW=(HT>1)?$clog2(HT):1;
    localparam integer VW=(VT>1)?$clog2(VT):1;
    reg [HW-1:0] h;
    reg [VW-1:0] v;
    always @(posedge pixel_clk) begin
        if (rst) begin h<=0; v<=0; end
        else if (h==HT-1) begin
            h<=0;
            if (v==VT-1) v<=0; else v<=v+1'b1;
        end else h<=h+1'b1;
    end
    assign de=!rst && h>=HB && h<HB+H_ACTIVE && v>=VB && v<VB+V_ACTIVE;
    assign x=de ? h-HB : 11'd0;
    assign y=de ? v-VB : 10'd0;
    assign hsync=(!rst && h<H_SYNC)?HS_ACTIVE:!HS_ACTIVE;
    assign vsync=(!rst && v<V_SYNC)?VS_ACTIVE:!VS_ACTIVE;
    assign frame_start=!rst && h==0 && v==0;
    // One pixel pulse on entering the front porch after the last active line.
    assign vblank_start=!rst && h==0 && v==VB+V_ACTIVE;
`ifndef SYNTHESIS
    initial begin
        if (H_SYNC<1 || V_SYNC<1 || H_BACK<0 || H_FRONT<1 || V_BACK<0 || V_FRONT<1 ||
            H_ACTIVE<1 || H_ACTIVE>2048 || V_ACTIVE<1 || V_ACTIVE>1024)
            $fatal(1,"Invalid scan geometry");
    end
`endif
endmodule
