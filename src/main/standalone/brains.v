module brains(
    input wire clk,
    input wire rst_n,

    input wire [15:0] d_in,


    //reduce reuse ecycee
    output  reg [2:0] alu_command,
    output  reg [2:0] tritwise_command,
    output  reg [2:0] tritshift_tritwise_command, //trit shifts up to 3 front and back
    //4 trit
    output reg [7:0] alu_t4_a,
    output reg [7:0] alu_t4_b,
    output reg [7:0] alu_t4_c,
    output reg [1:0] alu_t1_a,
    output reg [1:0] alu_t1_b,
    //results here
    input wire [7:0] alu_t4_o,
    input wire [1:0] alu_t1_o,
    input wire [15:0] alu_multiply_o

);
endmodule