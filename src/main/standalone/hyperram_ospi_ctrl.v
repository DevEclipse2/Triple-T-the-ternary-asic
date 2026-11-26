`default_nettype none

module hyperram_ospi_ctrl #(
    parameter [3:0] LATENCY_CYCLES = 4'd6, // Default POR CR0[7:4] = 6 clocks
    parameter [2:0] RECOVERY_CLKS  = 3'd2  // Extra CK cycles with CS#=1 (t_RWR)
)(
    input  wire        clk,
    input  wire        rst_n,

    // Host Interface
    input  wire        req,          //pulse or hold high to start transaction
    input  wire        rw,           //1 = Read, 0 = Write
    input  wire [23:0] addr_in,      //16-bit word address (32MB = 16M words)
    input  wire [15:0] data_in,      //write data: [15:8]=Byte A, [7:0]=Byte B
    output reg  [15:0] data_out,     //read data:  [15:8]=Byte A, [7:0]=Byte B
    output reg         data_ready,   //1-cycle pulse when Read/Write completes
    output wire [2:0]  status,       //[2]=rw_latched, [1]=extra_lat_2x, [0]=busy

    //ram lanes
    output reg         hb_cs_n,
    output reg         hb_ck,
    output wire        hb_reset_n,
    input  wire [7:0]  hb_dq_in,
    output reg  [7:0]  hb_dq_out,
    output reg         hb_dq_oe,     // 1 = Controller drives DQ, 0 = High-Z
    input  wire        hb_rwds_in,
    output reg         hb_rwds_out,
    output reg         hb_rwds_oe    // 1 = Controller drives RWDS, 0 = High-Z
);


    localparam [2:0] S_IDLE     = 3'd0;
    localparam [2:0] S_CS_SETUP = 3'd1;
    localparam [2:0] S_CA       = 3'd2;
    localparam [2:0] S_LATENCY  = 3'd3;
    localparam [2:0] S_DATA     = 3'd4;
    localparam [2:0] S_CS_HOLD  = 3'd5;
    localparam [2:0] S_RECOVERY = 3'd6;

    reg [2:0]  state;
    reg [1:0]  phase;       // 0..3 sub-cycle phase (4 clk = 1 hb_ck)
    reg [4:0]  ck_cnt;      // Counts full hb_ck cycles within a state
    reg        rw_reg;      // Latched R/W#
    reg        extra_lat;   // Latched RWDS during CA (1 = 2x latency)
    reg [47:0] ca_shift;    // 6-byte Command-Address shift register
    reg [15:0] wdata_reg;   // Latched write data

    assign hb_reset_n = rst_n;
    assign status     = {rw_reg, extra_lat, (state != S_IDLE)};

    // Precompute remaining latency cycles after CA2 (CA2 = latency cycle 1)
    wire [4:0] wait_cycles = extra_lat ? ({LATENCY_CYCLES, 1'b0} - 5'd1)
                                       : ({1'b0, LATENCY_CYCLES} - 5'd1);

    always @(posedge clk) begin
        if (!rst_n) begin
            state       <= S_IDLE;
            phase       <= 2'd0;
            ck_cnt      <= 5'd0;
            rw_reg      <= 1'b0;
            extra_lat   <= 1'b0;
            ca_shift    <= 48'd0;
            wdata_reg   <= 16'd0;
            data_out    <= 16'd0;
            data_ready  <= 1'b0;
            hb_cs_n     <= 1'b1;
            hb_ck       <= 1'b0;
            hb_dq_out   <= 8'd0;
            hb_dq_oe    <= 1'b0;
            hb_rwds_out <= 1'b0;
            hb_rwds_oe  <= 1'b0;
        end else begin
            data_ready <= 1'b0;

            case (state)
            
                S_IDLE: begin
                    hb_cs_n    <= 1'b1;
                    hb_ck      <= 1'b0;
                    hb_dq_oe   <= 1'b0;
                    hb_rwds_oe <= 1'b0;
                    phase      <= 2'd0;
                    ck_cnt     <= 5'd0;

                    if (req) begin
                        rw_reg    <= rw;
                        wdata_reg <= data_in;
                        // CA[47]=R/W#, CA[46]=0(Mem), CA[45]=1(Linear),
                        // CA[44:37]=0, CA[36:16]=addr[23:3], CA[15:3]=0, CA[2:0]=addr[2:0]
                        ca_shift  <= {rw, 1'b0, 1'b1, 8'd0, addr_in[23:3], 13'd0, addr_in[2:0]};
                        hb_cs_n   <= 1'b0;
                        state     <= S_CS_SETUP;
                    end
                end

                // ---------------------------------------------------------
                // Satisfy t_CSS (CS# setup to first CK rising edge) & t_DSV
                // ---------------------------------------------------------
                S_CS_SETUP: begin
                    hb_dq_oe  <= 1'b1;
                    hb_dq_out <= ca_shift[47:40];
                    if (phase == 2'd3) begin
                        phase  <= 2'd0;
                        ck_cnt <= 5'd0;
                        state  <= S_CA;
                    end else begin
                        phase <= phase + 2'd1;
                    end
                end

                // ---------------------------------------------------------
                // Shift out 6 CA bytes over 3 CK cycles (DDR, center-aligned)
                // Sample RWDS during CA0 to detect 1x vs 2x latency
                // ---------------------------------------------------------
                S_CA: begin
                    case (phase)
                        2'd0: begin
                            hb_ck     <= 1'b0;
                            hb_dq_out <= ca_shift[47:40]; // Rising-edge byte
                        end
                        2'd1: begin
                            hb_ck <= 1'b1;
                            if (ck_cnt == 5'd0)
                                extra_lat <= hb_rwds_in;  // 1=2x, 0=1x latency
                        end
                        2'd2: begin
                            hb_ck     <= 1'b1;
                            hb_dq_out <= ca_shift[39:32]; // Falling-edge byte
                        end
                        2'd3: begin
                            hb_ck    <= 1'b0;
                            ca_shift <= {ca_shift[31:0], 16'd0};
                            if (ck_cnt == 5'd2) begin
                                ck_cnt   <= 5'd0;
                                hb_dq_oe <= 1'b0; // Release DQ during latency
                                state    <= S_LATENCY;
                            end else begin
                                ck_cnt <= ck_cnt + 5'd1;
                            end
                        end
                    endcase
                    phase <= phase + 2'd1;
                end

                // ---------------------------------------------------------
                // Wait (Latency - 1) CK cycles.
                // On writes, drive RWDS=0 on the last latency cycle (preamble).
                // ---------------------------------------------------------
                S_LATENCY: begin
                    case (phase)
                        2'd0: begin
                            hb_ck <= 1'b0;
                            if (!rw_reg && (ck_cnt == wait_cycles - 5'd1)) begin
                                hb_rwds_oe  <= 1'b1;
                                hb_rwds_out <= 1'b0; // Unmasked write preamble
                            end
                        end
                        2'd1: hb_ck <= 1'b1;
                        2'd2: hb_ck <= 1'b1;
                        2'd3: begin
                            hb_ck <= 1'b0;
                            if (ck_cnt == wait_cycles - 5'd1) begin
                                ck_cnt <= 5'd0;
                                state  <= S_DATA;
                            end else begin
                                ck_cnt <= ck_cnt + 5'd1;
                            end
                        end
                    endcase
                    phase <= phase + 2'd1;
                end

                // ---------------------------------------------------------
                // Transfer 16-bit word (Byte A on CK rise, Byte B on CK fall)
                // ---------------------------------------------------------
                S_DATA: begin
                    if (rw_reg) begin
                        // READ: Sample DQ after CK transitions (synchronous mode)
                        case (phase)
                            2'd0: hb_ck <= 1'b0;
                            2'd1: hb_ck <= 1'b1;
                            2'd2: begin
                                hb_ck          <= 1'b1;
                                data_out[15:8] <= hb_dq_in; // Capture Byte A
                            end
                            2'd3: begin
                                hb_ck <= 1'b0;
                                state <= S_CS_HOLD;
                            end
                        endcase
                    end else begin
                        // WRITE: Drive DQ center-aligned with CK, RWDS=0 (no mask)
                        case (phase)
                            2'd0: begin
                                hb_ck       <= 1'b0;
                                hb_dq_oe    <= 1'b1;
                                hb_dq_out   <= wdata_reg[15:8]; // Byte A
                                hb_rwds_oe  <= 1'b1;
                                hb_rwds_out <= 1'b0;
                            end
                            2'd1: hb_ck <= 1'b1;
                            2'd2: begin
                                hb_ck     <= 1'b1;
                                hb_dq_out <= wdata_reg[7:0];    // Byte B
                            end
                            2'd3: begin
                                hb_ck <= 1'b0;
                                state <= S_CS_HOLD;
                            end
                        endcase
                    end
                    phase <= phase + 2'd1;
                end

                // ---------------------------------------------------------
                // Capture Read Byte B (after CK fell) & satisfy t_CSH
                // ---------------------------------------------------------
                S_CS_HOLD: begin
                    hb_ck <= 1'b0;
                    if (phase == 2'd0 && rw_reg) begin
                        data_out[7:0] <= hb_dq_in; // Capture Byte B
                    end
                    if (phase == 2'd1) begin
                        hb_cs_n    <= 1'b1;
                        hb_dq_oe   <= 1'b0;
                        hb_rwds_oe <= 1'b0;
                        data_ready <= 1'b1; // Signal host: transaction done
                        phase      <= 2'd0;
                        ck_cnt     <= 5'd0;
                        state      <= S_RECOVERY;
                    end else begin
                        phase <= phase + 2'd1;
                    end
                end

                // ---------------------------------------------------------
                // Enforce CS# high recovery time (t_CSHI / t_RWR)
                // ---------------------------------------------------------
                S_RECOVERY: begin
                    hb_cs_n <= 1'b1;
                    hb_ck   <= 1'b0;
                    if (phase == 2'd3) begin
                        phase <= 2'd0;
                        if (ck_cnt == {2'd0, RECOVERY_CLKS} - 5'd1) begin
                            state <= S_IDLE;
                        end else begin
                            ck_cnt <= ck_cnt + 5'd1;
                        end
                    end else begin
                        phase <= phase + 2'd1;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule