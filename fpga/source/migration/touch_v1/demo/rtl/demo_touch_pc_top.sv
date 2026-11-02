`timescale 1ns/1ps
// DRAFT_UNVERIFIED final top candidate; no routed or hardware acceptance.
// One renderer RGB bundle feeds both registered LCD I/O and eth_image.
// GT profile/power attestation default OFF; synthetic FW is never a deploy default.
module demo_touch_pc_top #(
    parameter integer SIM_TRIGGER_CYCLES=0,
    parameter integer RESET_CYCLES=1000000,BACKLIGHT_CYCLES=10000000,
    parameter bit TOUCH_PROFILE_CONFIGURED=0,TOUCH_POWER_STABLE_CONFIRMED=0,
    parameter bit TOUCH_PROFILE_GT911=0,TOUCH_PROFILE_FT=0,
    parameter bit TOUCH_FT_MAP_CONFIRMED=0,TOUCH_FT_SWAP_XY=0,
    parameter integer TOUCH_FT_RAW_WIDTH=4096,TOUCH_FT_RAW_HEIGHT=4096,
    parameter [15:0] TOUCH_FT_VERSION_BE_EXACT=16'h0001,
    parameter [15:0] TOUCH_FW_EXACT=16'h0000
)(input wire sys_clk,sys_rst_n,
    input wire eth_rxc,eth_rx_ctl,input wire [3:0] eth_rxd,
    output wire eth_txc,eth_tx_ctl,output wire [3:0] eth_txd,
    output wire eth_rst_n,eth_mdc,inout wire eth_mdio,
    output wire lcd_clk,output reg [7:0] lcd_r=0,lcd_g=0,lcd_b=0,
    output reg lcd_hsync=1,lcd_vsync=1,lcd_de=0,lcd_rst=0,lcd_bl=0,
    // INT is driven/released only for startup address selection; polling does
    // not sample an interrupt input. Keep its implemented tri-state direction.
    output wire touch_scl,touch_rst,touch_int,inout wire touch_sda);
    wire clk,pixel_clk,net_clk,ref_clk,rst,locked;
`ifdef ETH_SIM_CLOCKS
    eth_sim_clocks clocks(.*);
`else
    eth_clocks clocks(.*);
`endif
    wire net_rst,ref_rst,rx_rst,rx_clk,delay_ready;
    eth_reset net_reset(.clk(net_clk),.request(!sys_rst_n||!locked),.rst(net_rst));
    eth_reset #(.DEPTH(16)) ref_reset(.clk(ref_clk),.request(!sys_rst_n||!locked),.rst(ref_rst));
    eth_reset receive_reset(.clk(rx_clk),.request(!sys_rst_n||!locked||!delay_ready),.rst(rx_rst));
    wire phy_gigabit,phy_fault;wire [15:0] phy_status;
    eth_phy phy(.clk(clk),.rst(rst),.eth_rst_n(eth_rst_n),.eth_mdc(eth_mdc),.eth_mdio(eth_mdio),
        .gigabit(phy_gigabit),.fault(phy_fault),.status(phy_status));
    wire link_up,phy_link_sync,delay_ready_sync;
    xpm_cdc_single #(.DEST_SYNC_FF(3),.SRC_INPUT_REG(0)) link_sync(
        .src_clk(clk),.src_in(phy_gigabit),.dest_clk(net_clk),.dest_out(phy_link_sync));
    xpm_cdc_single #(.DEST_SYNC_FF(3),.SRC_INPUT_REG(0)) delay_sync(
        .src_clk(ref_clk),.src_in(delay_ready),.dest_clk(net_clk),.dest_out(delay_ready_sync));
    assign link_up=phy_link_sync&&delay_ready_sync;
    wire [7:0] gmii_rx_data,gmii_tx_data;wire gmii_rx_dv,gmii_rx_error,gmii_tx_en;
    eth_rgmii pins(.ref_clk(ref_clk),.ref_rst(ref_rst),.net_clk(net_clk),.net_rst(net_rst),
        .eth_rxc(eth_rxc),.eth_rx_ctl(eth_rx_ctl),.eth_rxd(eth_rxd),.eth_txc(eth_txc),
        .eth_tx_ctl(eth_tx_ctl),.eth_txd(eth_txd),.rx_clk(rx_clk),.rx_data(gmii_rx_data),
        .rx_dv(gmii_rx_dv),.rx_error(gmii_rx_error),.tx_data(gmii_tx_data),.tx_en(gmii_tx_en),.delay_ready(delay_ready));
    localparam SW=$clog2(BACKLIGHT_CYCLES+1);
    reg [SW-1:0] startup=0;
    always @(posedge pixel_clk)begin
        if(rst)begin startup<=0;lcd_rst<=0;lcd_bl<=0;end
        else begin
            if(startup<BACKLIGHT_CYCLES)startup<=startup+1'b1;
            lcd_rst<=startup>=RESET_CYCLES-1;
            lcd_bl<=startup>=BACKLIGHT_CYCLES-1;
        end
    end
    wire scan_reset=rst || !lcd_rst;
    wire scan_hsync,scan_vsync,scan_de,frame_start,vblank_start;
    wire [10:0] scan_x;wire [9:0] scan_y;
    lcd_timing scan(.pixel_clk(pixel_clk),.rst(scan_reset),.hsync(scan_hsync),.vsync(scan_vsync),
        .de(scan_de),.x(scan_x),.y(scan_y),.frame_start(frame_start),.vblank_start(vblank_start));
    wire [7:0] rx_data,tx_data;
    wire rx_valid,rx_ready,tx_valid,tx_ready;
    wire group_enqueued;
    wire [31:0] processing_cycles,debug_accepted;
    wire [15:0] debug_epoch;
    wire [31:0] uart_groups_queued,uart_groups_dropped,uart_groups_sent,uart_responses_queued,uart_queue_errors;
    wire [7:0] uart_queued_items;
    wire freeze=1'b0;
    wire out_de,out_hsync,out_vsync,front_valid,swapped,render_busy;
    wire [10:0] out_x;
    wire [9:0] out_y;
    wire [23:0] out_rgb;
    wire [31:0] front_frame_id,display_drops,invalid_descriptors,submitted_frames,failed_frames,dropped_frames,rejected_frames;
    wire [15:0] front_epoch;
    wire [511:0] front_status;
    wire [287:0] front_config;
    wire [31:0] actual_phase;wire [15:0] actual_amplitude,actual_epoch;
    wire [84:0] display_feedback;wire feedback_valid,feedback_updated;
    wire control_reset,pixel_reset,touch_available;
    wire storage_reset,rx_ready_storage,tx_valid_storage;
    demo_dualtime_runtime_display #(.SIM_TRIGGER_CYCLES(SIM_TRIGGER_CYCLES),
        .PROFILE_CONFIGURED(TOUCH_PROFILE_CONFIGURED),.PROFILE_GT911(TOUCH_PROFILE_GT911),.FW_EXACT(TOUCH_FW_EXACT),
        .PROFILE_FT(TOUCH_PROFILE_FT),.FT_MAP_CONFIRMED(TOUCH_FT_MAP_CONFIRMED),
        .FT_SWAP_XY(TOUCH_FT_SWAP_XY),.FT_RAW_WIDTH(TOUCH_FT_RAW_WIDTH),
        .FT_RAW_HEIGHT(TOUCH_FT_RAW_HEIGHT),.FT_VERSION_BE_EXACT(TOUCH_FT_VERSION_BE_EXACT)) core(
        .clk_50(pixel_clk),.rst_n(sys_rst_n && locked),
        .power_ready(locked && TOUCH_PROFILE_CONFIGURED && TOUCH_POWER_STABLE_CONFIRMED),
        .touch_reset_n(touch_rst),.touch_scl(touch_scl),.touch_sda(touch_sda),.touch_int(touch_int),
        .presets_ready(1'b1),.preset_phase_0(32'h08000000),
        .preset_phase_1(32'h1a000000),.preset_phase_2(32'h28000000),.*);
    wire [23:0] status_rgb=out_rgb;
    always @(posedge pixel_clk)begin
        if(scan_reset)begin {lcd_r,lcd_g,lcd_b}<=0;lcd_de<=0;lcd_hsync<=1;lcd_vsync<=1;end
        else begin
            {lcd_r,lcd_g,lcd_b}<=status_rgb;lcd_de<=out_de;lcd_hsync<=out_hsync;lcd_vsync<=out_vsync;
        end
    end
    ODDR #(.DDR_CLK_EDGE("SAME_EDGE"),.INIT(1'b0),.SRTYPE("SYNC")) pclk_out(
        .Q(lcd_clk),.C(pixel_clk),.CE(1'b1),.D1(1'b0),.D2(1'b1),.R(1'b0),.S(1'b0));

    wire [7:0] command_data;wire command_valid,command_ready;
    wire [8:0] response_data;wire response_valid,response_ready;
    reg net_storage_reset=1'b1;
    always @(posedge net_clk)net_storage_reset<=net_rst;
    demo_command_bridge control(.command_reset(net_storage_reset),.rst(storage_reset),.clk(clk),.net_clk(net_clk),
        .command_data(command_data),.command_valid(command_valid),.command_ready(command_ready),
        .response_data(response_data),.response_valid(response_valid),.response_ready(response_ready),
        .rx_data(rx_data),.rx_valid(rx_valid),.rx_ready(rx_ready_storage),.tx_data(tx_data),.tx_valid(tx_valid_storage),.tx_ready(tx_ready));
    wire packet_valid,packet_release;wire [10:0] packet_length,packet_addr;wire [7:0] packet_data;
    wire [31:0] mac_drops;
    eth_mac_rx receive(.rst(rst),.rx_clk(rx_clk),.rx_rst(rx_rst),.net_clk(net_clk),.net_rst(net_rst),
        .rx_data(gmii_rx_data),.rx_dv(gmii_rx_dv),.rx_error(gmii_rx_error),
        .release_packet(packet_release),.read_addr(packet_addr),.read_data(packet_data),
        .valid(packet_valid),.length(packet_length),.drops(mac_drops));
    wire image_valid,image_take,image_done,stream_enable;wire [15:0] image_sum;
    wire [10:0] image_addr;wire [7:0] image_data;wire [31:0] session_id,capture_drops,rejected;
    eth_image image_sender(.rst(pixel_reset),.pixel_clk(pixel_clk),.net_clk(net_clk),.net_rst(net_rst),
        .frame_start(frame_start),.front_valid(front_valid),.de(out_de),.rgb(status_rgb),
        .source_frame(front_frame_id),.epoch(front_epoch),.enable(stream_enable),.session_id(session_id),
        .packet_valid(image_valid),.packet_take(image_take),.packet_done(image_done),
        .read_addr(image_addr),.read_data(image_data),.payload_sum(image_sum),.capture_drops(capture_drops));
    demo_eth_endpoint endpoint(.clk(net_clk),.rst(net_rst),.link_up(link_up),
        .diagnostic_link_flags({phy_link_sync,delay_ready_sync}),
        .rx_valid(packet_valid),.rx_length(packet_length),.rx_release(packet_release),.rx_addr(packet_addr),.rx_data(packet_data),
        .command_data(command_data),.command_valid(command_valid),.command_ready(command_ready),
        .response_data(response_data),.response_valid(response_valid),.response_ready(response_ready),
        .image_valid(image_valid),.image_sum(image_sum),.image_data(image_data),.image_take(image_take),.image_done(image_done),
        .image_addr(image_addr),.tx_en(gmii_tx_en),.tx_data(gmii_tx_data),.stream_enable(stream_enable),
        .session_id(session_id),.rejected(rejected));
`ifndef SYNTHESIS
    initial if(RESET_CYCLES<1 || BACKLIGHT_CYCLES<=RESET_CYCLES)
        $fatal(1,"Invalid demo startup parameters");
`endif
endmodule
