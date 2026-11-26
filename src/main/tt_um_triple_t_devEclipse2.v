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
wire norm_oe [7:0];

assign io_oe = ui_in[0] ? norm_oe : 8'd0;



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


endmodule