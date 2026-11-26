`default_nettype none

module octalram_opi_ctrl #(
    parameter [3:0] LATENCY_CYCLES = 4'd5, // 3.0V POR default CR[7:4]=0010 -> 5 clocks
    parameter [2:0] RECOVERY_CLKS  = 3'd2  // Extra SCLK cycles with CS#=1 (t_RWR)
)(
    input  wire        clk,          // 50 MHz system clock (4x SCLK)
    input  wire        rst_n,

    // Host Interface
    input  wire        req,          // Start transaction (level or pulse)
    input  wire        rw,           // 1 = Read, 0 = Write
    input  wire        burst_6b,     // 0 = 3 bytes (12 trits), 1 = 6 bytes (24 trits)
    input  wire [23:0] addr_in,      // 16-bit word address: [23:9]=RA[14:0], [8:0]=CA[9:1]
    input  wire [47:0] data_in,      // 3B mode uses [23:0]; 6B mode uses [47:0]
    output reg  [47:0] data_out,     // 3B mode lands in [23:0]; 6B mode lands in [47:0]
    output reg         data_ready,   // 1-cycle (50 MHz) pulse on completion
    output wire [2:0]  status,       // [2]=rw_latched, [1]=refresh_col_2lc, [0]=busy

    // OctalRAM (DTR OPI) PHY Pins
    output reg         opi_cs_n,
    output reg         opi_sclk,
    output wire        opi_reset_n,
    input  wire [7:0]  opi_sio_in,
    output reg  [7:0]  opi_sio_out,
    output reg         opi_sio_oe,
    input  wire        opi_dqsm_in,
    output reg         opi_dqsm_out,
    output reg         opi_dqsm_oe
);

    localparam [7:0] CMD_MEM_READ  = 8'hA0;
    localparam [7:0] CMD_MEM_WRITE = 8'h20;

    localparam [2:0] S_IDLE     = 3'd0;
    localparam [2:0] S_CS_SETUP = 3'd1;
    localparam [2:0] S_CA       = 3'd2;
    localparam [2:0] S_LATENCY  = 3'd3;
    localparam [2:0] S_DATA     = 3'd4;
    localparam [2:0] S_CS_HOLD  = 3'd5;
    localparam [2:0] S_RECOVERY = 3'd6;

    reg [2:0]  state;
    reg [1:0]  phase;
    reg [4:0]  ck_cnt;
    reg [1:0]  word_cnt;
    reg        rw_reg;
    reg        burst_6b_reg;
    reg        refresh_col;
    reg [47:0] ca_shift;
    reg [47:0] wdata_shift;

    assign opi_reset_n = rst_n;
    assign status      = {rw_reg, refresh_col, (state != S_IDLE)};

    wire [4:0] wait_cycles = refresh_col ? ({LATENCY_CYCLES, 1'b0} - 5'd1)
                                         : ({1'b0, LATENCY_CYCLES} - 5'd1);
    wire [1:0] last_word   = burst_6b_reg ? 2'd2 : 2'd1; // 3 words (6B) or 2 words (3B+mask)

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state        <= S_IDLE;
            phase        <= 2'd0;
            ck_cnt       <= 5'd0;
            word_cnt     <= 2'd0;
            rw_reg       <= 1'b0;
            burst_6b_reg <= 1'b0;
            refresh_col  <= 1'b0;
            ca_shift     <= 48'd0;
            wdata_shift  <= 48'd0;
            data_out     <= 48'd0;
            data_ready   <= 1'b0;
            opi_cs_n     <= 1'b1;
            opi_sclk     <= 1'b0;
            opi_sio_out  <= 8'd0;
            opi_sio_oe   <= 1'b0;
            opi_dqsm_out <= 1'b0;
            opi_dqsm_oe  <= 1'b0;
        end else begin
            data_ready <= 1'b0;

            case (state)
                S_IDLE: begin
                    opi_cs_n    <= 1'b1;
                    opi_sclk    <= 1'b0;
                    opi_sio_oe  <= 1'b0;
                    opi_dqsm_oe <= 1'b0;
                    phase       <= 2'd0;
                    ck_cnt      <= 5'd0;
                    word_cnt    <= 2'd0;

                    if (req) begin
                        rw_reg       <= rw;
                        burst_6b_reg <= burst_6b;
                        // Left-align 3-byte writes so [47:40] is always first byte
                        wdata_shift  <= burst_6b ? data_in : {data_in[23:0], 24'd0};
                        if (rw) data_out <= 48'd0;
                        ca_shift     <= {
                            (rw ? CMD_MEM_READ : CMD_MEM_WRITE), 8'h00,
                            1'b0, addr_in[23:17], addr_in[16:9],
                            6'd0, addr_in[8:7],   addr_in[6:0], 1'b0
                        };
                        opi_cs_n     <= 1'b0;
                        state        <= S_CS_SETUP;
                    end
                end

                S_CS_SETUP: begin
                    opi_sio_oe  <= 1'b1;
                    opi_sio_out <= ca_shift[47:40];
                    if (phase == 2'd3) begin
                        phase  <= 2'd0;
                        ck_cnt <= 5'd0;
                        state  <= S_CA;
                    end else begin
                        phase <= phase + 2'd1;
                    end
                end

                S_CA: begin
                    case (phase)
                        2'd0: begin
                            opi_sclk    <= 1'b0;
                            opi_sio_out <= ca_shift[47:40];
                        end
                        2'd1: begin
                            opi_sclk <= 1'b1;
                            if (ck_cnt == 5'd0)
                                refresh_col <= opi_dqsm_in;
                        end
                        2'd2: begin
                            opi_sclk    <= 1'b1;
                            opi_sio_out <= ca_shift[39:32];
                        end
                        2'd3: begin
                            opi_sclk <= 1'b0;
                            ca_shift <= {ca_shift[31:0], 16'd0};
                            if (ck_cnt == 5'd2) begin
                                ck_cnt     <= 5'd0;
                                opi_sio_oe <= 1'b0;
                                state      <= S_LATENCY;
                            end else begin
                                ck_cnt <= ck_cnt + 5'd1;
                            end
                        end
                    endcase
                    phase <= phase + 2'd1;
                end

                S_LATENCY: begin
                    case (phase)
                        2'd0: begin
                            opi_sclk <= 1'b0;
                            if (!rw_reg && (ck_cnt == wait_cycles - 5'd1)) begin
                                opi_dqsm_oe  <= 1'b1;
                                opi_dqsm_out <= 1'b0; // Write mask preamble (t_DMV)
                            end
                        end
                        2'd1: opi_sclk <= 1'b1;
                        2'd2: opi_sclk <= 1'b1;
                        2'd3: begin
                            opi_sclk <= 1'b0;
                            if (ck_cnt == wait_cycles - 5'd1) begin
                                ck_cnt   <= 5'd0;
                                word_cnt <= 2'd0;
                                state    <= S_DATA;
                            end else begin
                                ck_cnt <= ck_cnt + 5'd1;
                            end
                        end
                    endcase
                    phase <= phase + 2'd1;
                end

                S_DATA: begin
                    if (rw_reg) begin
                        // READ: 40 ns (2-cycle) capture window per byte
                        case (phase)
                            2'd0: opi_sclk <= 1'b0;
                            2'd1: begin
                                // Capture falling-edge byte of PREVIOUS word
                                if (word_cnt != 2'd0)
                                    data_out <= {data_out[39:0], opi_sio_in};
                                opi_sclk <= 1'b1;
                            end
                            2'd2: opi_sclk <= 1'b1;
                            2'd3: begin
                                // Capture rising-edge byte of CURRENT word
                                data_out <= {data_out[39:0], opi_sio_in};
                                opi_sclk <= 1'b0;
                                if (word_cnt == last_word)
                                    state <= S_CS_HOLD;
                                else
                                    word_cnt <= word_cnt + 2'd1;
                            end
                        endcase
                    end else begin
                        // WRITE: Mask Byte 3 (falling edge of word 1) in 3-byte mode
                        case (phase)
                            2'd0: begin
                                opi_sclk     <= 1'b0;
                                opi_sio_oe   <= 1'b1;
                                opi_sio_out  <= wdata_shift[47:40];
                                opi_dqsm_oe  <= 1'b1;
                                opi_dqsm_out <= 1'b0;
                            end
                            2'd1: opi_sclk <= 1'b1;
                            2'd2: begin
                                opi_sclk     <= 1'b1;
                                opi_sio_out  <= wdata_shift[39:32];
                                opi_dqsm_out <= (!burst_6b_reg && (word_cnt == 2'd1)) ? 1'b1 : 1'b0;
                            end
                            2'd3: begin
                                opi_sclk    <= 1'b0;
                                wdata_shift <= {wdata_shift[31:0], 16'd0};
                                if (word_cnt == last_word)
                                    state <= S_CS_HOLD;
                                else
                                    word_cnt <= word_cnt + 2'd1;
                            end
                        endcase
                    end
                    phase <= phase + 2'd1;
                end

                S_CS_HOLD: begin
                    opi_sclk <= 1'b0;
                    if (phase == 2'd1) begin
                        // Capture final falling-edge byte ONLY in 6-byte mode
                        if (rw_reg && burst_6b_reg)
                            data_out <= {data_out[39:0], opi_sio_in};
                        opi_cs_n    <= 1'b1;
                        opi_sio_oe  <= 1'b0;
                        opi_dqsm_oe <= 1'b0;
                        data_ready  <= 1'b1;
                        phase       <= 2'd0;
                        ck_cnt      <= 5'd0;
                        state       <= S_RECOVERY;
                    end else begin
                        phase <= phase + 2'd1;
                    end
                end

                S_RECOVERY: begin
                    opi_cs_n <= 1'b1;
                    opi_sclk <= 1'b0;
                    if (phase == 2'd3) begin
                        phase <= 2'd0;
                        if (ck_cnt == {2'd0, RECOVERY_CLKS} - 5'd1)
                            state <= S_IDLE;
                        else
                            ck_cnt <= ck_cnt + 5'd1;
                    end else begin
                        phase <= phase + 2'd1;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule