`timescale 1ns/1ps
// Compress a monotonic-x connected pixel stream to one min/max span per column.
// pixel_last terminates each curve; no next-curve pixel is accepted until flush.
module plot_span_accumulator(
    input wire clk,rst,pixel_valid,pixel_last,
    input wire [9:0] pixel_x,pixel_y,
    output wire pixel_ready,
    output reg span_valid,span_last,
    input wire span_ready,
    output reg [9:0] span_x,span_y_min,span_y_max
);
    reg pending,flush_pending;
    reg [9:0] column,low_y,high_y;
    wire output_available=!span_valid || span_ready;
    assign pixel_ready=!rst && !flush_pending && output_available;
    always @(posedge clk) begin
        if(rst) begin
            pending<=0;flush_pending<=0;span_valid<=0;span_last<=0;
            column<=0;low_y<=0;high_y<=0;span_x<=0;span_y_min<=0;span_y_max<=0;
        end else begin
            if(span_valid && span_ready) span_valid<=0;
            if(flush_pending && output_available) begin
                span_valid<=1;span_last<=1;span_x<=column;span_y_min<=low_y;span_y_max<=high_y;
                pending<=0;flush_pending<=0;
            end else if(pixel_valid && pixel_ready) begin
                if(!pending) begin
                    pending<=1;column<=pixel_x;low_y<=pixel_y;high_y<=pixel_y;
                end else if(pixel_x!=column) begin
                    span_valid<=1;span_last<=0;span_x<=column;span_y_min<=low_y;span_y_max<=high_y;
                    column<=pixel_x;low_y<=pixel_y;high_y<=pixel_y;
                end else begin
                    if(pixel_y<low_y) low_y<=pixel_y;
                    if(pixel_y>high_y) high_y<=pixel_y;
                end
                if(pixel_last) flush_pending<=1;
            end
        end
    end
endmodule
