`timescale 1ns/1ps
// One-clock sample-to-point mapping, inclusive 768 x 192 plot rectangles.
// No interpolation/rasterization here. Values use the frozen wire formats.
module plot_coordinate_mapper(
    input wire clk,rst,in_valid,is_spectrum,
    input wire [9:0] sample_index,sample_count,
    input wire signed [15:0] sample_value,
    output reg out_valid,
    output reg [9:0] x,y
);
    reg legal;
    reg [19:0] numerator;
    reg [9:0] x_offset;
    reg [15:0] inverted;
    reg [23:0] y_product;
    reg [9:0] mapped_y;
    always @* begin
        legal=1;
        numerator=sample_index*20'd767;
        x_offset=0;
        // Explicit constant divisors; no run-time variable divider.
        if(is_spectrum) begin
            case(sample_count)
                129:x_offset=numerator>>7;
                257:x_offset=numerator>>8;
                default:legal=0;
            endcase
            inverted=sample_value>=0 ? 0 : -{sample_value[15],sample_value};
            y_product=inverted*24'd191;
            mapped_y=10'd336+(y_product>>15);
        end else begin
            case(sample_count)
                64:x_offset=numerator/20'd63;
                128:x_offset=numerator/20'd127;
                256:x_offset=numerator/20'd255;
                512:x_offset=numerator/20'd511;
                default:legal=0;
            endcase
            inverted=17'sd32767-$signed(sample_value);
            y_product=inverted*24'd191;
            mapped_y=10'd80+y_product/24'd65535;
        end
        if(sample_index>=sample_count) legal=0;
    end
    always @(posedge clk) begin
        if(rst) begin out_valid<=0;x<=0;y<=0;end
        else begin
            out_valid<=in_valid && legal;
            if(in_valid && legal) begin x<=10'd64+x_offset;y<=mapped_y;end
        end
    end
endmodule
