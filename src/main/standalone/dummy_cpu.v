`default_nettype none

(* keep_hierarchy *)
module dummy_cpu (
    input  wire        clk,          // 50 MHz shared clock
    input  wire        rst_n,
    input  wire        core_ce,      // 1-cycle enable every 4 clocks (12.5 MHz)
    input  wire        run_en,       // Tie to ui_in to start/pause test

    // Interface to OSPI Controller
    output reg         mem_req,
    output reg         mem_rw,
    output reg         mem_burst_6b,
    output reg  [23:0] mem_addr,
    output reg  [47:0] mem_wdata,
    input  wire [47:0] mem_rdata,
    input  wire        mem_ready,    // Stretched sticky ready pulse
    input  wire [2:0]  mem_status,

    // Debug outputs
    output reg         err_flag,
    output wire [1:0]  dbg_state
);

    localparam [1:0] C_COMPUTE = 2'd0;
    localparam [1:0] C_WRITE   = 2'd1;
    localparam [1:0] C_READ    = 2'd2;
    localparam [1:0] C_CHECK   = 2'd3;

    reg [1:0]  cstate;
    reg [23:0] acc_a;
    reg [23:0] acc_b;
    reg [47:0] expected;

    assign dbg_state = cstate;

    // Deliberately deep combinational path (~30-45 ns on GF180MCU)
    // to prove set_multicycle_path 4 is actually applied by OpenSTA.
    wire [31:0] prod1   = acc_a[15:0] * acc_b[15:0];
    wire [31:0] prod2   = (prod1[15:0] ^ acc_a[23:8]) * (acc_b[23:8] + 16'h0013);
    wire [23:0] next_a  = prod2[23:0] + acc_a + 24'h13579B;
    wire [23:0] next_b  = (prod1[31:8] ^ prod2[31:8]) + acc_b;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cstate       <= C_COMPUTE;
            acc_a        <= 24'h123456;
            acc_b        <= 24'h654321;
            expected     <= 48'd0;
            mem_req      <= 1'b0;
            mem_rw       <= 1'b0;
            mem_burst_6b <= 1'b0;
            mem_addr     <= 24'd0;
            mem_wdata    <= 48'd0;
            err_flag     <= 1'b0;
        end else if (core_ce) begin
            case (cstate)
                C_COMPUTE: begin
                    if (run_en && !mem_status[0]) begin
                        acc_a        <= next_a;
                        acc_b        <= next_b;
                        mem_burst_6b <= next_a[0]; // Alternate 3B and 6B
                        mem_addr     <= {8'd0, next_a[15:0]};
                        mem_wdata    <= next_a[0] ? {next_a, next_b} : {24'd0, next_a};
                        expected     <= next_a[0] ? {next_a, next_b} : {24'd0, next_a};
                        mem_rw       <= 1'b0; // Write
                        mem_req      <= 1'b1;
                        cstate       <= C_WRITE;
                    end
                end

                C_WRITE: begin
                    if (mem_status[0]) mem_req <= 1'b0; // Clear once accepted
                    if (mem_ready) begin
                        mem_rw  <= 1'b1; // Read back same address & size
                        mem_req <= 1'b1;
                        cstate  <= C_READ;
                    end
                end

                C_READ: begin
                    if (mem_status[0]) mem_req <= 1'b0;
                    if (mem_ready) begin
                        cstate <= C_CHECK;
                    end
                end

                C_CHECK: begin
                    if (mem_rdata != expected)
                        err_flag <= 1'b1;
                    cstate <= C_COMPUTE;
                end
            endcase
        end
    end

endmodule