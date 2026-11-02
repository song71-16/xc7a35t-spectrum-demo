`ifndef DEMO_TOUCH_UI_DEFS_VH
`define DEMO_TOUCH_UI_DEFS_VH
// Shared hit regions for the planned minimal overlay, inclusive coordinates.
// Existing plots end at y=527; the old SOURCE caption must move before integration.
`define DEMO_BUTTON_Y0 16'd560
`define DEMO_BUTTON_Y1 16'd599
`define DEMO_FREQ1_X0 16'd64
`define DEMO_FREQ1_X1 16'd207
`define DEMO_FREQ2_X0 16'd220
`define DEMO_FREQ2_X1 16'd363
`define DEMO_FREQ3_X0 16'd376
`define DEMO_FREQ3_X1 16'd519
`define DEMO_DOWN_X0 16'd532
`define DEMO_DOWN_X1 16'd675
`define DEMO_UP_X0 16'd688
`define DEMO_UP_X1 16'd831
`define DEMO_ACTION_NONE 3'd0
`define DEMO_ACTION_PENDING 3'd1
`define DEMO_ACTION_APPLIED 3'd2
`define DEMO_ACTION_FAILED 3'd3
`define DEMO_ACTION_UNKNOWN 3'd4
`define DEMO_NOTICE_NONE 4'd0
`define DEMO_NOTICE_BUSY 4'd1
`define DEMO_NOTICE_OUTSIDE 4'd2
`define DEMO_NOTICE_MULTITOUCH 4'd3
`define DEMO_NOTICE_UNAVAILABLE 4'd4
`define DEMO_NOTICE_INVALID 4'd5
`define DEMO_NOTICE_ID_EXHAUSTED 4'd6
`define DEMO_NOTICE_NOT_ADMITTED 4'd7
`define DEMO_NOTICE_PROTOCOL 4'd8
`define DEMO_NOTICE_PRESETS 4'd9
`endif
