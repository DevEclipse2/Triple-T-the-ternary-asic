`default_nettype none
//the toppest level of all time
module tt_um_triple_t_devEclipse2 (
    `ifdef USE_POWER_PINS
    inout VDD_3V3,  // Hidden from Yosys, used by OpenROAD
    inout VSS,
    `endif

    input  wire [7:0] ui_in,    // Dedicated inputs (Pins 0-7)
    output wire [7:0] uo_out,   // Dedicated outputs (Pins 16-23)
    input  wire [7:0] uio_in,   // IOs: Input path (Pins 8-15)
    output wire [7:0] uio_out,  // IOs: Output path (Pins 8-15)
    output wire [7:0] uio_oe,   // IOs: Enable path (active high: 1=drive, 0=high-Z)
    // inout  wire [7:0] ua,
    input  wire       ena,      // Always 1 when powered
    input  wire       clk,      // Clock 
    input  wire       rst_n     // Reset (Active low)
);


//if ui_in[0] is low, it's receiving direct commands from an fpga

//3 modules gpio driver
//alu
//spi driver
//can switch it's own command intake and data intake ports between spi sources with timeout functions
/*
buffers:
command 2-4 bytes
transfer(32 bits),
additional(64 bits) (used as a very crappy command pipe)
state buf
the state buffer allows very simple stuff to run without the alu actively participating
eg sd spi read to store at additional,
open to octalram, send out


the slimming down of the alu
no more macroop register
no more extended register
no next macro op param
no pc special treatment
no more overlord
*/

// 1/4 clock enable for 12.5 MHz core
    reg [1:0] div_cnt;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) div_cnt <= 2'd0;
        else        div_cnt <= div_cnt + 2'd1;
    end
    wire core_ce = (div_cnt == 2'd3);

    // Interconnect wires
    wire        mem_req, mem_rw, mem_burst_6b;
    wire [23:0] mem_addr;
    wire [47:0] mem_wdata, mem_rdata;
    wire        mem_ready_50m;
    wire [2:0]  mem_status;
    wire        err_flag;
    wire [1:0]  dbg_state;

    // Stretch 50 MHz data_ready pulse so 12.5 MHz core never misses it
    reg mem_ready_sticky;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)            mem_ready_sticky <= 1'b0;
        else if (mem_ready_50m) mem_ready_sticky <= 1'b1;
        else if (core_ce)      mem_ready_sticky <= 1'b0;
    end

    // OSPI PHY signals
    wire       opi_cs_n, opi_sclk, opi_reset_n;
    wire [7:0] opi_sio_out;
    wire       opi_sio_oe;
    wire       opi_dqsm_out, opi_dqsm_oe;

    octalram_opi_ctrl u_opi (
        .clk          (clk),
        .rst_n        (rst_n),
        .req          (mem_req),
        .rw           (mem_rw),
        .burst_6b     (mem_burst_6b),
        .addr_in      (mem_addr),
        .data_in      (mem_wdata),
        .data_out     (mem_rdata),
        .data_ready   (mem_ready_50m),
        .status       (mem_status),
        .opi_cs_n     (opi_cs_n),
        .opi_sclk     (opi_sclk),
        .opi_reset_n  (opi_reset_n),
        .opi_sio_in   (uio_in),
        .opi_sio_out  (opi_sio_out),
        .opi_sio_oe   (opi_sio_oe),
        .opi_dqsm_in  (ui_in[0]),
        .opi_dqsm_out (opi_dqsm_out),
        .opi_dqsm_oe  (opi_dqsm_oe)
    );

    dummy_cpu u_core (
        .clk          (clk),
        .rst_n        (rst_n),
        .core_ce      (core_ce),
        .run_en       (ui_in[1]),
        .mem_req      (mem_req),
        .mem_rw       (mem_rw),
        .mem_burst_6b (mem_burst_6b),
        .mem_addr     (mem_addr),
        .mem_wdata    (mem_wdata),
        .mem_rdata    (mem_rdata),
        .mem_ready    (mem_ready_sticky),
        .mem_status   (mem_status),
        .err_flag     (err_flag),
        .dbg_state    (dbg_state)
    );

    // Pin Assignments
    assign uio_out = opi_sio_out;
    assign uio_oe  = {8{opi_sio_oe}};

    assign uo_out[0]   = opi_cs_n;
    assign uo_out[1]   = opi_sclk;
    assign uo_out[2]   = opi_reset_n;
    assign uo_out[3]   = opi_dqsm_out;
    assign uo_out[4]   = opi_dqsm_oe;
    assign uo_out[5]   = err_flag;
    assign uo_out[7:6] = dbg_state;

    wire _unused = &{ena, ui_in[7:2], 1'b0};

endmodule