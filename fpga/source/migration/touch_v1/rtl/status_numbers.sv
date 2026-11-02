`timescale 1ns/1ps
// Snapshot at scan-frame start; finish during vertical back porch.
// Shared restoring divider and double-dabble formatter, no combinational divide.
module status_numbers(
    input wire clk,rst,start,valid,
    input wire [31:0] frame_id,
    input wire [15:0] epoch,
    input wire [511:0] status,
    output reg ready,shown_valid,peak_valid,peak_negative,noise_negative,filtered,
    output reg [15:0] flags,
    output wire [439:0] decimal_values
);
    reg [39:0] digits[0:10];
    genvar g; generate for(g=0;g<11;g=g+1) begin:packed_digits
        assign decimal_values[g*40+:40]=digits[g];
    end endgenerate
    reg [31:0] values[0:10];
    reg [63:0] dividend,divisor,remainder,quotient;
    reg [5:0] step;
    reg [3:0] field;
    reg [2:0] state;
    localparam IDLE=0,DIVIDE=1,LOAD=2,BCD=3,STORE=4;
    reg [31:0] binary;
    reg [39:0] bcd,adjusted;
    wire [64:0] trial={remainder,dividend[63]};
    wire subtract=trial>={1'b0,divisor};
    wire signed [31:0] bin_q15=$signed({1'b0,status[224+:16],15'b0})+
        $signed({{16{status[255]}},status[240+:16]});
    wire [31:0] fft_decim=status[64+:16]*status[32+:16];
    wire [63:0] denominator={17'b0,fft_decim,15'b0};
    wire [63:0] numerator=$unsigned(bin_q15)*status[0+:32];
    wire peak_ok=valid && status[112] && status[0+:32]!=0 && fft_decim!=0 &&
        bin_q15>=0 && $unsigned(bin_q15)<={1'b0,status[64+:16],14'b0};
    function [31:0] db_cents(input [15:0] bits);
        reg [16:0] magnitude;
        begin magnitude=bits[15] ? 17'd65536-{1'b0,bits} : {1'b0,bits};
            db_cents=(magnitude*32'd100+32'd128)>>8;
        end
    endfunction
    integer i;
    always @* begin
        adjusted=bcd;
        for(integer k=0;k<10;k=k+1)
            if(bcd[k*4+:4]>=5) adjusted[k*4+:4]=bcd[k*4+:4]+4'd3;
    end
    always @(posedge clk) begin
        if(rst) begin
            ready<=0;shown_valid<=0;peak_valid<=0;peak_negative<=0;noise_negative<=0;
            filtered<=0;flags<=0;state<=IDLE;step<=0;field<=0;
            dividend<=0;divisor<=1;remainder<=0;quotient<=0;binary<=0;bcd<=0;
            for(i=0;i<11;i=i+1) begin digits[i]<=0;values[i]<=0;end
        end else if(start) begin
            ready<=0;shown_valid<=valid;peak_valid<=peak_ok;filtered<=status[104+:8]==1;
            peak_negative<=status[271];noise_negative<=status[287];flags<=status[112+:16];
            values[0]<=frame_id;values[1]<={16'b0,epoch};values[2]<={16'b0,status[64+:16]};
            values[3]<=status[0+:32];values[4]<={16'b0,status[32+:16]};
            values[5]<={16'b0,status[48+:16]};values[6]<=0;
            values[7]<=db_cents(status[256+:16]);values[8]<=db_cents(status[272+:16]);
            values[9]<=status[192+:32];values[10]<=status[416+:32];
            dividend<=numerator+(denominator>>1);divisor<=denominator;
            remainder<=0;quotient<=0;step<=0;field<=0;
            state<=peak_ok ? DIVIDE : LOAD;
        end else case(state)
            DIVIDE:begin
                remainder<=subtract ? trial-{1'b0,divisor} : trial;
                dividend<={dividend[62:0],1'b0};quotient<={quotient[62:0],subtract};
                if(step==63) begin values[6]<={quotient[30:0],subtract};state<=LOAD;end
                else step<=step+1'b1;
            end
            LOAD:begin binary<=values[field];bcd<=0;step<=0;state<=BCD;end
            BCD:begin
                bcd<={adjusted[38:0],binary[31]};binary<={binary[30:0],1'b0};
                if(step==31) state<=STORE;else step<=step+1'b1;
            end
            STORE:begin
                digits[field]<=bcd;
                if(field==10) begin ready<=1;state<=IDLE;end
                else begin field<=field+1'b1;state<=LOAD;end
            end
            default:state<=IDLE;
        endcase
    end
endmodule
