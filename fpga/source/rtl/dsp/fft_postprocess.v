`timescale 1ns/1ps
// FFT power -> calibrated dBFS, plus log-parabolic isolated-peak interpolation.
// Bounded 32-cycle end-of-frame division; all arithmetic is synthesizable.
module fft_postprocess #(
    parameter integer N=512,
    parameter integer FFT_W=16+$clog2(N)+1,
    parameter integer DB_OFFSET_Q8=(N==256 ? -32358 : -33904),
    parameter LOG_FILE="log2_fraction.mem"
)(
    input wire clk,input wire rst,
    input wire signed[31:0]in_real,input wire signed[31:0]in_imag,
    input wire[15:0]in_index,input wire in_valid,output wire in_ready,input wire in_last,
    output reg spectrum_we,output reg[15:0]spectrum_addr,
    output reg signed[15:0]spectrum_db_q8_8,
    output reg done,output reg[15:0]peak_bin,output reg signed[15:0]peak_fraction,
    output reg signed[15:0]peak_dbfs,output reg signed[15:0]noise_floor,
    output reg[7:0]flags
);
    localparam PW=2*FFT_W+1;
    localparam IDLE=0,PREPARE=1,DIVIDE=2,MEDIAN_INIT=3,MEDIAN_SCAN=4,MEDIAN_DECIDE=5,FINISH=6;
    localparam BINS=N/2+1;
    reg[2:0]state;
    reg end_pending,frame_error;
    reg[15:0]expected_index;
    reg[12:0]log_rom[0:1023];
    reg[2*FFT_W-1:0]square_real,square_imag;
    reg[PW-1:0]power_2;
    reg[15:0]index_1,index_2,index_3,index_log,index_4;
    reg v1,v2,v3,v_log,v4;
    reg zero_3,zero_log,zero_4;
    reg[5:0]exponent_3;
    reg[9:0]fraction_addr_3;
    (* keep="true" *) reg[19:0]log2_q12;
    reg signed[39:0]db_product;
    reg signed[15:0]maximum_db,left_db,right_db,previous_db;
    reg signed[39:0]maximum_detection_db;
    reg[15:0]maximum_index;
    reg any_signal;
    reg[31:0]divide_numerator,divide_denominator,divide_quotient;
    reg[32:0]divide_remainder;
    reg[5:0]divide_count;
    reg divide_negative,interpolate_protected;
    reg signed[17:0]left_minus_right;
    reg signed[15:0]fraction_work;
    reg signed[15:0]spectrum_memory[0:BINS-1];
    reg[15:0]median_prefix;
    reg[15:0]median_scan_addr,median_zero_count,median_remaining_rank;
    reg[4:0]median_bit;
    reg floor_clamped;
    integer exponent,bitpos;
    reg[9:0]fraction_addr;
    reg[PW-1:0]normalized;
    reg signed[39:0]db_wide;
    reg signed[39:0]detection_db;
    reg signed[15:0]db_value;
    reg signed[17:0]denominator_work,difference_work;
    reg[32:0]remainder_next;
    reg[31:0]quotient_next;
    reg signed[35:0]correction_product;
    reg signed[35:0]corrected_peak;
    assign in_ready=state==IDLE && !end_pending && !rst;
    initial $readmemh(LOG_FILE,log_rom);
    // Leading-one normalization and fractional logarithm. LUT stores
    // log2(1+i/1024) in UQ1.12, its truncation error is <0.0043 dB.
    always @* begin
        exponent=0;
        for(bitpos=0;bitpos<PW;bitpos=bitpos+1)
            if(power_2[bitpos]) exponent=bitpos;
        if(exponent>=10) normalized=power_2>>(exponent-10);
        else normalized=power_2<<(10-exponent);
        fraction_addr=normalized[9:0];
        detection_db=zero_4 ? -40'sd1000000 : (($signed(db_product)>>>20)+DB_OFFSET_Q8);
        db_wide=($signed(db_product)>>>20)+DB_OFFSET_Q8;
        if(index_4==0 || index_4==N/2) db_wide=db_wide-1541;
        if(zero_4 || db_wide < -32768) db_value=-16'sd32768;
        else if(db_wide>32767) db_value=16'sd32767;
        else db_value=db_wide[15:0];
        denominator_work=$signed(left_db)-($signed(maximum_db)<<<1)+$signed(right_db);
        difference_work=$signed(left_db)-$signed(right_db);
        remainder_next={divide_remainder[31:0],divide_numerator[31]};
        quotient_next=divide_quotient<<1;
        if(remainder_next>={1'b0,divide_denominator}) begin
            remainder_next=remainder_next-{1'b0,divide_denominator};quotient_next[0]=1;
        end
        correction_product=$signed(left_minus_right)*$signed(fraction_work);
        corrected_peak=$signed(maximum_db)-($signed(correction_product)>>>17);
    end
    always @(posedge clk) begin
        if(rst) begin
            state<=IDLE;end_pending<=0;frame_error<=0;expected_index<=0;
            square_real<=0;square_imag<=0;power_2<=0;log2_q12<=0;db_product<=0;
            index_1<=0;index_2<=0;index_3<=0;index_log<=0;index_4<=0;
            v1<=0;v2<=0;v3<=0;v_log<=0;v4<=0;zero_3<=1;zero_log<=1;zero_4<=1;
            exponent_3<=0;fraction_addr_3<=0;
            spectrum_we<=0;spectrum_addr<=0;spectrum_db_q8_8<=-16'sd32768;
            maximum_db<=-16'sd32768;left_db<=-16'sd32768;right_db<=-16'sd32768;previous_db<=-16'sd32768;maximum_index<=0;any_signal<=0;
            maximum_detection_db<=-40'sd1000000;
            divide_numerator<=0;divide_denominator<=1;divide_remainder<=0;divide_quotient<=0;divide_count<=0;
            divide_negative<=0;interpolate_protected<=0;left_minus_right<=0;fraction_work<=0;
            median_prefix<=0;median_scan_addr<=0;median_zero_count<=0;median_remaining_rank<=BINS/2;median_bit<=15;
            noise_floor<=-16'sd32768;floor_clamped<=0;
            done<=0;peak_bin<=0;peak_fraction<=0;peak_dbfs<=-16'sd32768;flags<=8'h01;
        end else begin
            done<=0;spectrum_we<=0;
            v1<=in_valid&&in_ready;v2<=v1;v3<=v2;v_log<=v3;v4<=v_log;
            if(in_valid&&in_ready) begin
                square_real<=$signed(in_real[FFT_W-1:0])*$signed(in_real[FFT_W-1:0]);
                square_imag<=$signed(in_imag[FFT_W-1:0])*$signed(in_imag[FFT_W-1:0]);
                index_1<=in_index;
                if(in_index!=expected_index || in_last!=(expected_index==N-1) ||
                   $signed(in_real)!=$signed(in_real[FFT_W-1:0]) ||
                   $signed(in_imag)!=$signed(in_imag[FFT_W-1:0])) frame_error<=1;
                expected_index<=expected_index+1'b1;
                if(expected_index==N-1) end_pending<=1;
            end
            if(v1) begin power_2<={1'b0,square_real}+{1'b0,square_imag};index_2<=index_1;end
            if(v2) begin
                exponent_3<=exponent;fraction_addr_3<=fraction_addr;
                index_3<=index_2;zero_3<=power_2==0;
            end
            if(v3)begin
                log2_q12<=({14'b0,exponent_3}<<12)+log_rom[fraction_addr_3];
                index_log<=index_3;zero_log<=zero_3;
            end
            if(v_log) begin db_product<=$signed({1'b0,log2_q12})*19'sd197283;index_4<=index_log;zero_4<=zero_log;end
            if(v4) begin
                if(index_4<=N/2) begin
                    spectrum_we<=1;spectrum_addr<=index_4;spectrum_db_q8_8<=db_value;
                    spectrum_memory[index_4]<=db_value;
                    if(zero_4 || db_wide< -32768)floor_clamped<=1;
                    if(!zero_4) any_signal<=1;
                    // Detect the peak before DC/Nyquist one-sided correction.
                    // Otherwise a Hann-windowed DC signal can falsely choose
                    // bin1, whose displayed amplitude receives a factor of 2.
                    if(index_4==0 || detection_db>maximum_detection_db) begin
                        maximum_detection_db<=detection_db;
                        maximum_db<=db_value;maximum_index<=index_4;left_db<=previous_db;right_db<=-16'sd32768;
                    end else if(index_4==maximum_index+1'b1) right_db<=db_value;
                    previous_db<=db_value;
                end
                if(index_4==N-1) state<=PREPARE;
            end
            case(state)
                PREPARE:begin
                    peak_bin<=maximum_index;left_minus_right<=difference_work;fraction_work<=0;
                    interpolate_protected<=0;
                    if(!any_signal || maximum_index==0 || maximum_index==N/2) state<=MEDIAN_INIT;
                    else if(denominator_work>=-1) begin interpolate_protected<=1;state<=MEDIAN_INIT;end
                    else begin
                        divide_denominator<=-$signed(denominator_work);
                        divide_numerator<=(difference_work<0 ? -$signed(difference_work) : difference_work)<<14;
                        divide_negative<=difference_work>0;divide_quotient<=0;divide_remainder<=0;divide_count<=0;state<=DIVIDE;
                    end
                end
                DIVIDE:begin
                    divide_numerator<=divide_numerator<<1;divide_remainder<=remainder_next;divide_quotient<=quotient_next;
                    if(divide_count==31) begin
                        if(quotient_next>16384) fraction_work<=divide_negative ? -16'sd16384 : 16'sd16384;
                        else fraction_work<=divide_negative ? -$signed(quotient_next[15:0]) : $signed(quotient_next[15:0]);
                        state<=MEDIAN_INIT;
                    end else divide_count<=divide_count+1'b1;
                end
                // Exact median selection by 16 prefix/count scans. One stored
                // value per cycle and a 16-bit prefix; no sorting network.
                MEDIAN_INIT:begin
                    median_prefix<=0;median_bit<=15;median_remaining_rank<=BINS/2;
                    median_scan_addr<=0;median_zero_count<=0;state<=MEDIAN_SCAN;
                end
                MEDIAN_SCAN:begin
                    if(((spectrum_memory[median_scan_addr]^16'h8000)>>(median_bit+1))==
                       (median_prefix>>(median_bit+1)) &&
                       (((spectrum_memory[median_scan_addr]^16'h8000)>>median_bit)&1)==0)
                        median_zero_count<=median_zero_count+1'b1;
                    if(median_scan_addr==BINS-1)state<=MEDIAN_DECIDE;
                    else median_scan_addr<=median_scan_addr+1'b1;
                end
                MEDIAN_DECIDE:begin
                    if(median_remaining_rank>=median_zero_count)begin
                        median_prefix<=median_prefix|(16'h0001<<median_bit);
                        median_remaining_rank<=median_remaining_rank-median_zero_count;
                    end
                    if(median_bit==0)begin
                        noise_floor<=(median_prefix|(median_remaining_rank>=median_zero_count?16'h0001:16'h0000))^16'h8000;
                        state<=FINISH;
                    end else begin
                        median_bit<=median_bit-1'b1;median_scan_addr<=0;median_zero_count<=0;state<=MEDIAN_SCAN;
                    end
                end
                FINISH:begin
                    peak_fraction<=fraction_work;
                    if(!any_signal || corrected_peak< -32768) peak_dbfs<=-16'sd32768;
                    else if(corrected_peak>32767) peak_dbfs<=16'sd32767;
                    else peak_dbfs<=corrected_peak[15:0];
                    flags<={4'b0,floor_clamped,interpolate_protected,frame_error,!any_signal};
                    done<=1;state<=IDLE;end_pending<=0;expected_index<=0;frame_error<=0;
                    maximum_db<=-16'sd32768;left_db<=-16'sd32768;right_db<=-16'sd32768;previous_db<=-16'sd32768;any_signal<=0;maximum_index<=0;
                    maximum_detection_db<=-40'sd1000000;
                    floor_clamped<=0;
                end
            endcase
        end
    end
endmodule
