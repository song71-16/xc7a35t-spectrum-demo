`timescale 1ns/1ps
module eth_clocks(input wire sys_clk,sys_rst_n,
    output wire clk,pixel_clk,net_clk,ref_clk,locked,output wire rst);
    wire input_clk,fb_raw,fb,c0,c1,c2,c3;
    IBUF input_buffer(.I(sys_clk),.O(input_clk));
    MMCME2_BASE #(.CLKIN1_PERIOD(20.0),.DIVCLK_DIVIDE(1),.CLKFBOUT_MULT_F(20.0),
        .CLKOUT0_DIVIDE_F(10.0),.CLKOUT1_DIVIDE(20),.CLKOUT2_DIVIDE(5),.CLKOUT3_DIVIDE(8)) mmcm(
        .CLKIN1(input_clk),.CLKFBIN(fb),.CLKFBOUT(fb_raw),.CLKOUT0(c0),.CLKOUT1(c1),
        .CLKOUT2(c2),.CLKOUT3(c3),.LOCKED(locked),.RST(!sys_rst_n),.PWRDWN(1'b0),
        .CLKFBOUTB(),.CLKOUT0B(),.CLKOUT1B(),.CLKOUT2B(),.CLKOUT3B(),.CLKOUT4(),.CLKOUT5(),.CLKOUT6());
    BUFG bf(.I(fb_raw),.O(fb));BUFG b0(.I(c0),.O(clk));BUFG b1(.I(c1),.O(pixel_clk));
    BUFG b2(.I(c2),.O(ref_clk));BUFG b3(.I(c3),.O(net_clk));
    wire request=!sys_rst_n || !locked;
    (* ASYNC_REG="TRUE",SHREG_EXTRACT="NO" *) reg [3:0] pipe=4'hf;
    always @(posedge pixel_clk or posedge request)
        if(request)pipe<=4'hf;else pipe<={pipe[2:0],1'b0};
    reg reset_q=1;
    always @(posedge pixel_clk)reset_q<=pipe[3];
    BUFG reset_buffer(.I(reset_q),.O(rst));
endmodule

module eth_reset #(parameter integer DEPTH=4)(input wire clk,request,output wire rst);
    (* ASYNC_REG="TRUE",SHREG_EXTRACT="NO" *) reg [DEPTH-1:0] pipe={DEPTH{1'b1}};
    always @(posedge clk or posedge request)
        if(request)pipe<={DEPTH{1'b1}};else pipe<={pipe[DEPTH-2:0],1'b0};
    assign rst=pipe[DEPTH-1];
endmodule
