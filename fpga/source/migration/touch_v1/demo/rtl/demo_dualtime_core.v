// DRAFT_UNVERIFIED dual-TIME derivative of migration/touch_v1/demo/rtl/demo_spectrum_queued_core.v.
// Demo D1 derivative of migration/touch_v1/generated/spectrum_queued_core.v at 0cb39cf.
// Initial derivation: demo/tools/derive_control_core.py. Original generator must not target this file.
// Paired raw (high16) and FIR (low16) share capture ownership and stride.
// FIR pipeline 7 + group delay 15 = raw delay22 at TAPS31; prove numerically.
// Legacy UART TIME still selects one channel; display always receives both.
`timescale 1ns/1ps
`include "protocol_defs.vh"
// Continuous signal path with bounded frame ownership and byte-stream protocol.
module demo_dualtime_core #(
    parameter integer N=512, TAPS=31, DW=16, CLOCK_HZ=100000000,
    parameter integer SIM_TRIGGER_CYCLES=0
)(
    input wire clk,rst,
    // All local/control feedback ports are synchronous to clk. No CDC here.
    input wire local_valid, input wire [1:0] local_op,
    input wire [31:0] local_argument, input wire [63:0] local_id,
    output wire local_ready, local_done, input wire local_take,
    output wire [7:0] local_status, output wire [63:0] local_result_id,
    output wire [31:0] local_result_step,
    output wire [15:0] local_result_amplitude, local_result_epoch,
    // Actual current bank, not a promise about an older displayed frame.
    output wire [31:0] actual_phase,
    output wire [15:0] actual_amplitude, actual_epoch,
    input wire [7:0] rx_data,input wire rx_valid,output wire rx_ready,
    output wire [7:0] tx_data,output wire tx_valid,input wire tx_ready,
    // Storage-facing beats may discard old bytes during common reset; only
    // clocked reset controls these ports, never a new owner commit.
    output wire storage_reset,rx_ready_storage,tx_valid_storage,
    output wire display_offer_storage,display_word_valid_storage,display_commit_storage,
    output wire group_enqueued,output reg [31:0] processing_cycles,
    output wire [15:0] debug_epoch,output wire [31:0] debug_accepted,
    output wire display_offer, display_word_valid, display_commit,
    output wire [31:0] display_frame_id,
    output wire [15:0] display_epoch, display_config_epoch,
    output wire [9:0] display_time_count, display_word_index,
    output wire [31:0] display_word_data,
    output wire [511:0] display_status,
    output wire [287:0] display_config,
    output wire [31:0] uart_groups_queued,uart_groups_dropped,uart_groups_sent,
    output wire [31:0] uart_responses_queued,uart_queue_errors,
    output wire [7:0] uart_queued_items
);
    // Full-reset ownership is revoked immediately; RAM controls remain timed.
    // This stage extends runtime release by one clock, never an independent reset.
    reg datapath_reset=1'b1;
    always @(posedge clk) datapath_reset<=rst;
    wire owner_reset=rst || datapath_reset;
    wire local_ready_int,local_done_int,rx_ready_int,tx_valid_int;
    reg group_enqueued_int;
    assign local_ready=!owner_reset && local_ready_int;
    assign local_done=!owner_reset && local_done_int;
    assign rx_ready=!owner_reset && rx_ready_int;
    assign tx_valid=!owner_reset && tx_valid_int;
    assign group_enqueued=!owner_reset && group_enqueued_int;
    assign storage_reset=datapath_reset;
    assign rx_ready_storage=!datapath_reset && rx_ready_int;
    assign tx_valid_storage=!datapath_reset && tx_valid_int;
    assign display_offer_storage=!datapath_reset && group_enqueued_int;
    localparam AW=$clog2(N), FIR_LAT=$clog2(TAPS/2+1)+3, RAW_DELAY=FIR_LAT+TAPS/2;
    localparam [7:0] STATUS_TAPS = TAPS;
    localparam [7:0] STATUS_DATA_WIDTH = DW;
    localparam [15:0] STATUS_FFT_SIZE = N;
    localparam [31:0] STATUS_SAMPLE_RATE = CLOCK_HZ;
    localparam IDLE=0,LOAD=1,FFT_SEND=2,FFT_WAIT=3,TIME_START=4,TIME_SEND=5,
               SPEC_START=6,SPEC_SEND=7,STATUS_START=8,STATUS_SEND=9,
               RESPONSE_START=10,RESPONSE_SEND=11,RELEASE=12;
    reg [3:0] state;
    wire run_enable,dual_enable,time_source;
    wire [31:0] phase_a,phase_b;
    wire [15:0] amp_a,amp_b,epoch;
    wire [7:0] trigger_fps;
    wire [2:0] time_stride;
    wire packet_valid,packet_release;
    wire [7:0] packet_type,command_data;
    wire [15:0] packet_length;
    wire [10:0] command_address;
    wire response_valid;
    wire [15:0] response_length,response_epoch;
    wire [7:0] response_data;
    wire crc_error,header_error,timeout_error;
    reg response_release;
    reg [63:0] cycle_count;
    reg [31:0] trigger_phase;
    reg trigger;
    reg [15:0] prior_epoch;
    reg config_reset;
    reg [15:0] warmup;
    reg [2:0] outstanding;
    wire capture_ready,capture_bank,trigger_accept,trigger_reject;
    wire post_done;
    wire capture_take=(state==IDLE && !response_valid && capture_ready);
    // A trigger/capture pulse is registered by pingpong_capture one cycle
    // after the scheduler asserts it. Include both registered handshakes and
    // a descriptor take so a command cannot commit between those edges.
    wire safe_commit=(outstanding==0 && !trigger && !trigger_accept && !capture_take && state==IDLE);
    assign debug_epoch=epoch;
    assign actual_phase=phase_a;
    assign actual_amplitude=amp_a;
    assign actual_epoch=epoch;
    // Use the registered BRAM read in the integrated path.  The control block
    // is parameterized to prefetch address 0 in PIPE, then samples the byte on
    // the following edge; this keeps the payload contract explicit and avoids
    // a long asynchronous RAM-address/control timing path.
    frame_rx #(.CLOCK_HZ(CLOCK_HZ),.SYNC_PAYLOAD_READ(1)) receiver(
        .clk(clk),.rst(datapath_reset),.byte_data(rx_data),.byte_valid(rx_valid),.byte_ready(rx_ready_int),
        .packet_valid(packet_valid),.packet_type(packet_type),.packet_length(packet_length),
        .packet_frame_id(),.packet_epoch(),.payload_addr(command_address),.payload_data(command_data),
        .packet_release(packet_release),.crc_error(crc_error),.header_error(header_error),.timeout_error(timeout_error));
    reg [15:0] payload_index;
    demo_runtime_control #(.FFT_N(N),.FIR_TAPS(TAPS),.DATA_WIDTH(DW),.SAMPLE_RATE_HZ(CLOCK_HZ),.SYNC_PAYLOAD_READ(1)) control(
        .local_valid(local_valid),.local_op(local_op),.local_argument(local_argument),.local_id(local_id),
        .local_ready(local_ready_int),.local_done(local_done_int),.local_take(local_take),
        .local_status(local_status),.local_result_id(local_result_id),
        .local_result_step(local_result_step),.local_result_amplitude(local_result_amplitude),
        .local_result_epoch(local_result_epoch),
        .clk(clk),.rst(owner_reset),.safe_commit(safe_commit),.packet_valid(packet_valid),.packet_type(packet_type),
        .packet_length(packet_length),.payload_addr(command_address),.payload_data(command_data),
        .packet_release(packet_release),.run_enable(run_enable),.dual_enable(dual_enable),
        .phase_inc_a(phase_a),.phase_inc_b(phase_b),.amplitude_a(amp_a),.amplitude_b(amp_b),
        .trigger_fps(trigger_fps),.time_source(time_source),.time_stride(time_stride),.config_epoch(epoch),
        .response_valid(response_valid),.response_length(response_length),.response_epoch(response_epoch),
        .response_addr(payload_index[10:0]),.response_data(response_data),.response_release(response_release));
    wire raw_valid,filtered_valid,dds_clip,fir_clip;
    wire signed [15:0] raw_sample,filtered_sample;
    wire configuration_changed=prior_epoch!=epoch;
    // Convert the epoch change into a registered one-cycle reset request.
    // This keeps the DSP reset synchronous to clk instead of feeding a
    // combinational comparison directly into a reset port.
    dsp_frontend #(.DW(DW),.TAPS(TAPS)) frontend(
        .clk(clk),.rst(datapath_reset || config_reset),.enable(1'b1),
        .phase_inc_a(phase_a),.phase_inc_b(phase_b),.amplitude_a(amp_a),.amplitude_b(amp_b),
        .dual_enable(dual_enable),.raw_valid(raw_valid),.raw_sample(raw_sample),
        .filtered_valid(filtered_valid),.filtered_sample(filtered_sample),.dds_clip(dds_clip),.fir_clip(fir_clip));
    reg signed [15:0] raw_delay[0:RAW_DELAY-1];
    integer d;
    wire [31:0] ready_id,trigger_count,accepted_count,reject_count;
    wire [15:0] ready_epoch;
    wire [63:0] ready_timestamp;
    reg active_bank;
    reg [31:0] active_id;
    reg [15:0] active_epoch;
    reg [63:0] active_timestamp;
    reg active_source;
    reg [2:0] active_stride;
    wire process_release=(state==FFT_WAIT && post_done);
    wire upload_release=(state==RELEASE);
    reg [AW:0] load_issued,window_written,fft_issued;
    reg [AW-1:0] process_index;
    wire process_read=(state==LOAD && load_issued<N);
    wire process_valid,upload_valid;
    wire signed [15:0] process_data;
    wire [31:0] upload_data;
    reg [AW-1:0] upload_addr;
    reg upload_pending,upload_have,upload_high;
    reg [31:0] upload_word;
    wire [15:0] legacy_time_word=active_source ? upload_word[15:0] : upload_word[31:16];
    wire upload_read=(state==TIME_SEND && payload_index < (2*N)/active_stride &&
                      !upload_have && !upload_pending);
    demo_dualtime_capture #(.DW(16),.N(N)) capture(
        .clk(clk),.rst(datapath_reset),.trigger(trigger),.config_epoch(epoch),.timestamp_cycles(cycle_count),
        .sample_valid(filtered_valid && warmup==0),.sample_in(filtered_sample),
        .upload_sample_in({raw_delay[RAW_DELAY-1],filtered_sample}),
        .trigger_accept(trigger_accept),.trigger_reject(trigger_reject),.trigger_count(trigger_count),
        .accepted_count(accepted_count),.trigger_reject_count(reject_count),
        .ready_valid(capture_ready),.ready_take(capture_take),.ready_bank(capture_bank),
        .ready_frame_id(ready_id),.ready_epoch(ready_epoch),.ready_timestamp(ready_timestamp),
        .process_release(process_release),.process_release_bank(active_bank),
        .upload_release(upload_release),.upload_release_bank(active_bank),
        .process_read_en(process_read),.process_read_bank(active_bank),.process_read_addr(load_issued[AW-1:0]),
        .process_read_valid(process_valid),.process_read_data(process_data),
        .upload_read_en(upload_read),.upload_read_bank(active_bank),.upload_read_addr(upload_addr),
        .upload_read_valid(upload_valid),.upload_read_data(upload_data));
    assign debug_accepted=accepted_count;
    wire window_valid;
    wire signed [15:0] window_data;
    window_hann #(.N(N),.DW(16)) hann(.clk(clk),.rst(datapath_reset),.in_valid(process_valid),
        .sample_in(process_data),.sample_index(process_index),.out_valid(window_valid),.sample_out(window_data));
    (* ram_style="block" *) reg signed [15:0] window_memory[0:N-1];
    reg fft_valid;
    reg signed [15:0] fft_sample;
    wire fft_ready,fft_out_valid,fft_out_ready,fft_last,fft_error;
    wire signed [31:0] fft_real,fft_imag;
    wire [15:0] fft_index;
    fft_wrapper #(.N(N)) fft(.clk(clk),.rst(datapath_reset),.in_data(fft_sample),.in_valid(fft_valid),
        .in_ready(fft_ready),.out_real(fft_real),.out_imag(fft_imag),.out_index(fft_index),
        .out_valid(fft_out_valid),.out_ready(fft_out_ready),.out_last(fft_last),.protocol_error(fft_error),.completed_frames());
    wire spectrum_we;
    wire [15:0] spectrum_addr,post_peak;
    wire signed [15:0] spectrum_db,post_fraction,post_dbfs,post_noise;
    wire [7:0] post_flags;
    fft_postprocess #(.N(N)) postprocessor(.clk(clk),.rst(datapath_reset),.in_real(fft_real),.in_imag(fft_imag),
        .in_index(fft_index),.in_valid(fft_out_valid),.in_ready(fft_out_ready),.in_last(fft_last),
        .spectrum_we(spectrum_we),.spectrum_addr(spectrum_addr),.spectrum_db_q8_8(spectrum_db),
        .done(post_done),.peak_bin(post_peak),.peak_fraction(post_fraction),.peak_dbfs(post_dbfs),
        .noise_floor(post_noise),.flags(post_flags));
    (* ram_style="distributed" *) reg [15:0] spectrum_memory[0:N/2];
    reg [31:0] overflow_count,processing_fail_count,rx_drop_count;
    wire [15:0] protocol_flags={13'b0,(overflow_count!=0),post_flags[3],!post_flags[0] && !post_flags[1] && !fft_error};
    reg [511:0] status_latched;
    wire [31:0] current_processing=cycle_count-active_timestamp;
    // Packed little-endian wire order matches the generated 64-byte schema.
    wire [511:0] status_current={32'b0,overflow_count,uart_groups_dropped,processing_fail_count,
        reject_count,accepted_count,trigger_count,post_noise,post_dbfs,post_fraction,post_peak,
        current_processing,active_timestamp,protocol_flags,{7'b0,active_source},8'd1,
        STATUS_DATA_WIDTH,STATUS_TAPS,STATUS_FFT_SIZE,{13'b0,active_stride},16'd1,STATUS_SAMPLE_RATE};
    wire start_ready,packet_done,packet_length_error,payload_ready;
    reg [7:0] tx_type,payload_data;
    reg [15:0] tx_length;
    wire tx_start=(state==TIME_START || state==SPEC_START || state==STATUS_START || state==RESPONSE_START);
    wire payload_valid=(state==TIME_SEND && upload_have) || state==SPEC_SEND || state==STATUS_SEND || state==RESPONSE_SEND;
    always @* begin
        tx_type=`PROTO_TYPE_TIME;tx_length=(2*N)/active_stride;payload_data=0;
        case(state)
            TIME_SEND:payload_data=upload_high ? legacy_time_word[15:8] : legacy_time_word[7:0];
            SPEC_START,SPEC_SEND:begin
                tx_type=`PROTO_TYPE_SPECTRUM;tx_length=2*(N/2+1);
                payload_data=payload_index[0] ? spectrum_memory[payload_index>>1][15:8] : spectrum_memory[payload_index>>1][7:0];
            end
            STATUS_START,STATUS_SEND:begin tx_type=`PROTO_TYPE_STATUS;tx_length=64;payload_data=status_latched[8*payload_index +: 8];end
            RESPONSE_START,RESPONSE_SEND:begin tx_type=`PROTO_TYPE_RESPONSE;tx_length=response_length;payload_data=response_data;end
        endcase
    end
    wire [7:0] producer_data;
    wire producer_valid,producer_ready;
    uart_group_queue transport(
        .clk(clk),.rst(datapath_reset),.begin_data(group_enqueued_int),
        .begin_response(state==RESPONSE_START && tx_start && start_ready),
        .end_item(packet_done && (state==STATUS_SEND || state==RESPONSE_SEND)),
        .in_data(producer_data),.in_valid(producer_valid),.in_ready(producer_ready),
        .out_data(tx_data),.out_valid(tx_valid_int),.out_ready(tx_ready),
        .groups_queued(uart_groups_queued),.groups_dropped(uart_groups_dropped),
        .groups_sent(uart_groups_sent),.responses_queued(uart_responses_queued),
        .queue_errors(uart_queue_errors),.queued_items(uart_queued_items));
    frame_tx encoder(.clk(clk),.rst(owner_reset),.start(tx_start),.start_ready(start_ready),.frame_type(tx_type),
        .payload_length(tx_length),.frame_id(state==RESPONSE_START || state==RESPONSE_SEND ? 32'b0 : active_id),
        .config_epoch(state==RESPONSE_START || state==RESPONSE_SEND ? response_epoch : active_epoch),
        .payload_data(payload_data),.payload_valid(payload_valid),.payload_ready(payload_ready),
        .byte_data(producer_data),.byte_valid(producer_valid),.byte_ready(producer_ready),.done(packet_done),.length_error(packet_length_error));
    // Data arrays/read data have no asynchronous reset cone. Ownership and
    // valid flags prevent any pre-reset contents escaping before a new frame.
    always @(posedge clk) begin
        if(!datapath_reset && window_valid)
            window_memory[window_written[AW-1:0]]<=window_data;
        if(!datapath_reset && spectrum_we)
            spectrum_memory[spectrum_addr[AW-1:0]]<=spectrum_db;
        if(!datapath_reset && upload_valid)upload_word<=upload_data;
        if(!datapath_reset && state==FFT_SEND && (!fft_valid || fft_ready) && fft_issued<N)
            fft_sample<=window_memory[fft_issued[AW-1:0]];
    end
    always @(posedge clk) begin
        if(owner_reset) begin
            state<=IDLE;cycle_count<=0;trigger_phase<=0;trigger<=0;prior_epoch<=0;config_reset<=0;warmup<=2*TAPS+32;outstanding<=0;
            active_bank<=0;active_id<=0;active_epoch<=0;active_timestamp<=0;active_source<=1;active_stride<=1;
            load_issued<=0;window_written<=0;fft_issued<=0;process_index<=0;fft_valid<=0;
            upload_addr<=0;upload_pending<=0;upload_have<=0;upload_high<=0;
            payload_index<=0;response_release<=0;group_enqueued_int<=0;processing_cycles<=0;status_latched<=0;
            overflow_count<=0;processing_fail_count<=0;rx_drop_count<=0;
            for(d=0;d<RAW_DELAY;d=d+1)raw_delay[d]<=0;
        end else begin
            cycle_count<=cycle_count+1'b1;config_reset<=configuration_changed;prior_epoch<=epoch;trigger<=0;response_release<=0;group_enqueued_int<=0;
            raw_delay[0]<=raw_sample;for(d=1;d<RAW_DELAY;d=d+1)raw_delay[d]<=raw_delay[d-1];
            if(configuration_changed) warmup<=2*TAPS+32;
            else if(warmup!=0)warmup<=warmup-1'b1;
            if(run_enable && warmup==0) begin
                if(SIM_TRIGGER_CYCLES!=0) begin
                    if(trigger_phase>=SIM_TRIGGER_CYCLES-1)begin trigger<=1;trigger_phase<=0;end
                    else trigger_phase<=trigger_phase+1'b1;
                end else if(trigger_phase+trigger_fps>=CLOCK_HZ)begin trigger<=1;trigger_phase<=trigger_phase+trigger_fps-CLOCK_HZ;end
                else trigger_phase<=trigger_phase+trigger_fps;
            end else trigger_phase<=0;
            case({trigger_accept,upload_release})
                2'b10:outstanding<=outstanding+1'b1;
                2'b01:outstanding<=outstanding-1'b1;
            endcase
            if(dds_clip || fir_clip)overflow_count<=overflow_count+1'b1;
            if(rx_valid && !rx_ready)rx_drop_count<=rx_drop_count+1'b1;
            if(process_read)begin process_index<=load_issued[AW-1:0];load_issued<=load_issued+1'b1;end
            if(window_valid)window_written<=window_written+1'b1;
            if(upload_read)upload_pending<=1;
            if(upload_valid)begin upload_have<=1;upload_pending<=0;end
            if(payload_valid && payload_ready) begin
                payload_index<=payload_index+1'b1;
                if(state==TIME_SEND)begin
                    upload_high<=!upload_high;
                    if(upload_high)begin upload_have<=0;upload_addr<=upload_addr+active_stride;end
                end
            end
            case(state)
                IDLE:begin
                    fft_valid<=0;
                    if(response_valid && !response_release)begin payload_index<=0;state<=RESPONSE_START;end
                    else if(capture_take)begin
                        active_bank<=capture_bank;active_id<=ready_id;active_epoch<=ready_epoch;active_timestamp<=ready_timestamp;
                        active_source<=time_source;active_stride<=time_stride;load_issued<=0;window_written<=0;state<=LOAD;
                    end
                end
                LOAD:if(window_valid && window_written==N-1)begin fft_issued<=0;state<=FFT_SEND;end
                FFT_SEND:begin
                    if((!fft_valid || fft_ready) && fft_issued<N)begin
                        fft_valid<=1;fft_issued<=fft_issued+1'b1;
                    end else if(fft_valid && fft_ready)begin fft_valid<=0;state<=FFT_WAIT;end
                end
                FFT_WAIT:if(post_done)begin
                    processing_cycles<=current_processing;status_latched<=status_current;group_enqueued_int<=1;
                    if(post_flags[1] || fft_error)processing_fail_count<=processing_fail_count+1'b1;
                    payload_index<=0;upload_addr<=0;upload_have<=0;upload_pending<=0;upload_high<=0;state<=TIME_START;
                end
                TIME_START:if(start_ready)state<=TIME_SEND;
                TIME_SEND:if(packet_done)begin payload_index<=0;state<=SPEC_START;end
                SPEC_START:if(start_ready)state<=SPEC_SEND;
                SPEC_SEND:if(packet_done)begin payload_index<=0;state<=STATUS_START;end
                STATUS_START:if(start_ready)state<=STATUS_SEND;
                STATUS_SEND:if(packet_done)state<=RELEASE;
                RELEASE:state<=IDLE;
                RESPONSE_START:if(start_ready)state<=RESPONSE_SEND;
                RESPONSE_SEND:if(packet_done)begin response_release<=1;state<=IDLE;end
                default:state<=IDLE;
            endcase
        end
    end

    // Internal producer observation path: independent of physical UART ready.
    // Complete output groups live in transport-owned slots before UART drain.
    // Capture ownership is released when internal formatting finishes.
    reg [7:0] display_low_byte;
    wire display_payload = state==TIME_SEND || state==SPEC_SEND;
    assign display_offer=group_enqueued;
    assign display_frame_id=active_id;
    assign display_epoch=active_epoch;
    assign display_config_epoch=epoch;
    assign display_time_count=active_stride==4 ? N/4 : active_stride==2 ? N/2 : N;
    assign display_status=status_latched;
    assign display_config={{29'b0,time_stride},{31'b0,time_source},{24'b0,trigger_fps},
                           {16'b0,amp_b},phase_b,{16'b0,amp_a},phase_a,
                           (dual_enable ? 32'd2 : 32'd1),{31'b0,run_enable}};
    assign display_word_valid=!owner_reset && display_payload && payload_valid && payload_ready && payload_index[0];
    assign display_word_valid_storage=!datapath_reset && display_payload && payload_valid && payload_ready && payload_index[0];
    assign display_word_data=state==TIME_SEND ? upload_word : {16'd0,payload_data,display_low_byte};
    assign display_word_index=(state==SPEC_SEND ? display_time_count : 10'd0)+(payload_index>>1);
    assign display_commit=!owner_reset && state==SPEC_SEND && packet_done;
    assign display_commit_storage=!datapath_reset && state==SPEC_SEND && packet_done;
    always @(posedge clk) begin
        if(owner_reset) display_low_byte<=0;
        else if(display_payload && payload_valid && payload_ready && !payload_index[0])
            display_low_byte<=payload_data;
    end
endmodule
