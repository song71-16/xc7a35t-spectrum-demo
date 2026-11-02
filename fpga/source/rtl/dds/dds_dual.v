`timescale 1ns / 1ps
// Two phase accumulators; amplitude is unsigned Q1.15 (0..32768).
// DW quantization occurs after the two full precision products are summed.
module dds_dual #(
    parameter integer DW = 16,
    parameter SINE_FILE = "dds_sine.mem"
)(
    input wire clk, input wire rst, input wire en,
    input wire [31:0] phase_inc_a, input wire [31:0] phase_inc_b,
    input wire [15:0] amplitude_a, input wire [15:0] amplitude_b,
    input wire dual_enable,
    output reg signed [DW-1:0] sample_out,
    output reg out_valid, output reg clip
);
    localparam integer SHIFT = 31-DW;
    reg signed [15:0] sine_rom [0:4095];
    reg [31:0] phase_a, phase_b;
    reg signed [15:0] sine_a, sine_b;
    reg [15:0] amp_a, amp_b;
    reg signed [32:0] product_a, product_b;
    reg dual_1, dual_2, valid_1, valid_2;
    wire signed [33:0] product_sum =
        {product_a[32], product_a} +
        (dual_2 ? {product_b[32], product_b} : 34'sd0);
    function signed [34:0] round_even;
        input signed [33:0] value;
        reg signed [34:0] quotient, remainder;
        begin
            quotient = $signed(value) >>> SHIFT;
            remainder = $signed(value) - (quotient <<< SHIFT);
            if ((remainder > (35'sd1 <<< (SHIFT-1))) ||
                ((remainder == (35'sd1 <<< (SHIFT-1))) && quotient[0]))
                quotient = quotient + 1'b1;
            round_even = quotient;
        end
    endfunction
    wire signed [34:0] rounded = round_even(product_sum);
    localparam signed [34:0] MAX_SAMPLE = (35'sd1 <<< (DW-1))-1;
    localparam signed [34:0] MIN_SAMPLE = -(35'sd1 <<< (DW-1));
    initial begin
        if (DW < 8 || DW > 16) $error("dds_dual DW must be 8..16");
        $readmemh(SINE_FILE, sine_rom);
    end
    always @(posedge clk) begin
        if (rst) begin
            phase_a <= 0; phase_b <= 0;
            sine_a <= 0; sine_b <= 0; amp_a <= 0; amp_b <= 0;
            product_a <= 0; product_b <= 0;
            dual_1 <= 0; dual_2 <= 0;
            valid_1 <= 0; valid_2 <= 0; out_valid <= 0;
            sample_out <= 0; clip <= 0;
        end else begin
            valid_1 <= en; valid_2 <= valid_1; out_valid <= valid_2;
            if (en) begin
                phase_a <= phase_a + phase_inc_a;
                phase_b <= phase_b + phase_inc_b;
                sine_a <= sine_rom[phase_a[31:20]];
                sine_b <= sine_rom[phase_b[31:20]];
                amp_a <= amplitude_a; amp_b <= amplitude_b;
                dual_1 <= dual_enable;
            end
            if (valid_1) begin
                product_a <= sine_a * $signed({1'b0, amp_a});
                product_b <= sine_b * $signed({1'b0, amp_b});
                dual_2 <= dual_1;
            end
            clip <= 0;
            if (valid_2) begin
                if (rounded > MAX_SAMPLE) begin
                    sample_out <= MAX_SAMPLE[DW-1:0]; clip <= 1;
                end else if (rounded < MIN_SAMPLE) begin
                    sample_out <= MIN_SAMPLE[DW-1:0]; clip <= 1;
                end else sample_out <= rounded[DW-1:0];
            end
        end
    end
endmodule
