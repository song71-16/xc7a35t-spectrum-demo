`timescale 1ns/1ps
// Integer Bresenham, increasing x only. Both segment endpoints are emitted.
// All transfers use valid && ready. Output remains stable while stalled.
module plot_line_rasterizer(
    input wire clk,rst,
    input wire point_valid,first_point,last_point,
    input wire [9:0] point_x,point_y,
    output wire point_ready,
    output wire pixel_valid,
    input wire pixel_ready,
    output reg [9:0] pixel_x,pixel_y,
    output wire pixel_last,
    output reg error_pulse
);
    reg busy,have_previous,end_curve;
    reg [9:0] previous_x,previous_y,target_x,target_y;
    reg signed [11:0] delta_x,delta_y,step_y,error_value;
    wire signed [12:0] twice_error=$signed(error_value)*13'sd2;
    wire advance_x=twice_error>=-$signed(delta_y);
    wire advance_y=twice_error<=$signed(delta_x);
    wire at_target=pixel_x==target_x && pixel_y==target_y;
    wire legal=point_x<1024 && point_y<600 &&
               (first_point || (have_previous && point_x>=previous_x));
    wire [9:0] distance_y=point_y>=previous_y ? point_y-previous_y : previous_y-point_y;
    assign point_ready=!busy && !rst;
    assign pixel_valid=busy && !rst;
    assign pixel_last=busy && end_curve && at_target;
    always @(posedge clk) begin
        if(rst) begin
            busy<=0;have_previous<=0;end_curve<=0;error_pulse<=0;
            pixel_x<=0;pixel_y<=0;previous_x<=0;previous_y<=0;target_x<=0;target_y<=0;
            delta_x<=0;delta_y<=0;step_y<=0;error_value<=0;
        end else begin
            error_pulse<=0;
            if(point_valid && point_ready) begin
                if(!legal) begin error_pulse<=1;have_previous<=0;end
                else begin
                    busy<=1;end_curve<=last_point;
                    target_x<=point_x;target_y<=point_y;
                    previous_x<=point_x;previous_y<=point_y;
                    have_previous<=!last_point;
                    if(first_point) begin
                        pixel_x<=point_x;pixel_y<=point_y;
                        delta_x<=0;delta_y<=0;step_y<=0;error_value<=0;
                    end else begin
                        pixel_x<=previous_x;pixel_y<=previous_y;
                        delta_x<=$signed({2'b0,point_x})-$signed({2'b0,previous_x});
                        delta_y<=$signed({2'b0,distance_y});
                        step_y<=point_y>=previous_y ? 12'sd1 : -12'sd1;
                        error_value<=$signed({2'b0,point_x})-$signed({2'b0,previous_x})-$signed({2'b0,distance_y});
                    end
                end
            end
            if(pixel_valid && pixel_ready) begin
                if(at_target) busy<=0;
                else begin
                    error_value<=error_value-(advance_x?delta_y:12'sd0)+(advance_y?delta_x:12'sd0);
                    if(advance_x) pixel_x<=pixel_x+1'b1;
                    if(advance_y) pixel_y<=pixel_y+step_y;
                end
            end
        end
    end
endmodule
