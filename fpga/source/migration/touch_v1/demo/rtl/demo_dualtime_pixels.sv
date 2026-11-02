// DRAFT_UNVERIFIED dual-TIME derivative of migration/touch_v1/rtl/plot_pixel_compositor.sv.
`timescale 1ns/1ps
// Connect column_* to the synchronous read port of plot_column_buffer.
// Two register stages from scan_* to out_*; RGB/sync/DE/coordinates stay aligned.
module demo_dualtime_pixels #(
    parameter bit HS_IDLE=1'b1, VS_IDLE=1'b1
)(
    input wire pixel_clk,rst,
    input wire scan_de,scan_hsync,scan_vsync,
    input wire [10:0] scan_x,
    input wire [9:0] scan_y,
    output wire column_read_en,
    output wire [9:0] column_read_index,
    input wire column_valid,
    input wire [7:0] time_min,time_max,filtered_min,filtered_max,spec_min,spec_max,
    output reg out_de,out_hsync,out_vsync,
    output reg [10:0] out_x,
    output reg [9:0] out_y,
    output reg [23:0] out_rgb
);
    reg de_q,hs_q,vs_q;
    reg [10:0] x_q;
    reg [9:0] y_q;
    reg [23:0] color;
    reg in_time,in_spec,in_plot;
    reg [9:0] local_y;
    assign column_read_en=!rst && scan_de && scan_x>=64 && scan_x<=831 &&
        ((scan_y>=80 && scan_y<=271)||(scan_y>=336 && scan_y<=527));
    assign column_read_index=column_read_en ? scan_x-11'd64 : 10'd0;
    always @* begin
        in_time=y_q>=80 && y_q<=271;
        in_spec=y_q>=336 && y_q<=527;
        in_plot=x_q>=64 && x_q<=831 && (in_time || in_spec);
        local_y=in_spec ? y_q-10'd336 : y_q-10'd80;
        color=24'h000000;
        if(de_q) begin
            color=24'h0b1322;
            if(in_plot) begin
                color=24'h101c2b;
                if(x_q==256 || x_q==448 || x_q==640 ||
                   local_y==47 || local_y==95 || local_y==143) color=24'h243448;
                if(x_q==64 || x_q==831 || local_y==0 || local_y==191) color=24'h94a3b8;
                // Curve wins over grid/border, including full-scale endpoint pixels.
                if(column_valid && in_time)begin
                    if(local_y>=time_min && local_y<=time_max)color=24'h49dfac;
                    if(local_y>=filtered_min && local_y<=filtered_max)color=24'hffb454;
                    if(local_y>=time_min && local_y<=time_max && local_y>=filtered_min && local_y<=filtered_max)color=24'hffffff;
                end
                if(column_valid && in_spec && local_y>=spec_min && local_y<=spec_max) color=24'h59b7ff;
            end
        end
    end
    always @(posedge pixel_clk) begin
        if(rst) begin
            de_q<=0;hs_q<=HS_IDLE;vs_q<=VS_IDLE;x_q<=0;y_q<=0;
            out_de<=0;out_hsync<=HS_IDLE;out_vsync<=VS_IDLE;out_x<=0;out_y<=0;out_rgb<=0;
        end else begin
            de_q<=scan_de;hs_q<=scan_hsync;vs_q<=scan_vsync;x_q<=scan_x;y_q<=scan_y;
            out_de<=de_q;out_hsync<=hs_q;out_vsync<=vs_q;out_x<=x_q;out_y<=y_q;out_rgb<=color;
        end
    end
endmodule
