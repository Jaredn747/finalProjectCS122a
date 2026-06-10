module top (
    input  wire CLK,

    // SPI slave — receives commands from Pico
    input  wire SPI_SCK,
    input  wire SPI_MOSI,
    input  wire SPI_CS,    // active low

    output wire LCD_CLK,
    output wire LCD_DEN,

    output reg [4:0] LCD_R,
    output reg [5:0] LCD_G,
    output reg [4:0] LCD_B,

    output wire BUZZER
);

    // Forward FPGA clock to LCD
    assign LCD_CLK = CLK;

    // LCD stuff
    localparam H_ACTIVE = 480;
    localparam H_TOTAL  = 525;

    localparam V_ACTIVE = 272;
    localparam V_TOTAL  = 285;

    // Screen counters
    reg [9:0] x_counter = 0;
    reg [9:0] y_counter = 0;

    always @(posedge CLK) begin
        if (x_counter == H_TOTAL - 1) begin
            x_counter <= 0;

            if (y_counter == V_TOTAL - 1)
                y_counter <= 0;
            else
                y_counter <= y_counter + 1;
        end else begin
            x_counter <= x_counter + 1;
        end
    end

    assign LCD_DEN = (x_counter < H_ACTIVE && y_counter < V_ACTIVE);

    // how does the grid shows
    localparam GRID_COLS = 16;
    localparam GRID_ROWS = 8;

    // Grid placement on screen
    localparam GRID_X0 = 16;
    localparam GRID_Y0 = 32;

    //448 pixels x  192 pixels gotta keep it
    localparam CELL_W = 28;
    localparam CELL_H = 24;

    localparam GRID_W = GRID_COLS * CELL_W;
    localparam GRID_H = GRID_ROWS * CELL_H;

    wire in_grid;
    assign in_grid =
        (x_counter >= GRID_X0) &&
        (x_counter <  GRID_X0 + GRID_W) &&
        (y_counter >= GRID_Y0) &&
        (y_counter <  GRID_Y0 + GRID_H);

    wire [9:0] grid_x;
    wire [9:0] grid_y;

    assign grid_x = x_counter - GRID_X0;
    assign grid_y = y_counter - GRID_Y0;

    wire [3:0] cell_col;
    wire [2:0] cell_row;

    assign cell_col = grid_x / CELL_W;
    assign cell_row = grid_y / CELL_H;

    wire [9:0] cell_x;
    wire [9:0] cell_y;

    assign cell_x = grid_x % CELL_W;
    assign cell_y = grid_y % CELL_H;

    // Draw grid lines
    wire is_grid_line;
    assign is_grid_line =
        in_grid &&
        ((cell_x == 0) || (cell_y == 0) ||
         (cell_x == CELL_W - 1) || (cell_y == CELL_H - 1));

    // ----------------------------------------------------------------
    // SPI Slave — receives 2-byte commands from Pico master
    //   Byte 0 (cmd):  0x80|step = NOTE_ON, 0x60|col = GRID_UPDATE
    //                  0x40|row  = CURSOR,   0x00   = NOTE_OFF
    //   Byte 1 (data): row mask or cursor column
    // ----------------------------------------------------------------

    // 2/3-stage synchronizers for external SPI signals (metastability protection)
    reg sck_r0=0, sck_r1=0, sck_r2=0;
    reg cs_r0=0,  cs_r1=0;
    reg mosi_r0=0, mosi_r1=0;

    always @(posedge CLK) begin
        sck_r0  <= SPI_SCK;  sck_r1  <= sck_r0;  sck_r2  <= sck_r1;
        cs_r0   <= SPI_CS;   cs_r1   <= cs_r0;
        mosi_r0 <= SPI_MOSI; mosi_r1 <= mosi_r0;
    end

    wire sck_rising = sck_r1 && !sck_r2;   // one-cycle pulse on SCK rising edge
    wire cs_sync    = cs_r1;                // synchronized CS (active low)

    // SPI state machine states
    localparam SPI_IDLE = 1'b0;
    localparam SPI_RECV = 1'b1;
    reg spi_state = SPI_IDLE;

    reg [6:0] spi_shift = 0;    // 7-bit accumulator; full byte = {spi_shift, mosi_r1}
    reg [2:0] bit_cnt   = 0;    // counts bits 0-7 within each byte
    reg       byte_idx  = 0;    // 0 = waiting for cmd byte, 1 = waiting for data byte
    reg [7:0] spi_cmd   = 0;    // latched command byte
    reg [7:0] spi_data  = 0;    // latched data byte
    reg       cmd_valid = 0;    // 1-cycle pulse when both bytes are ready

    always @(posedge CLK) begin
        cmd_valid <= 0;

        case (spi_state)
            SPI_IDLE: begin
                if (!cs_sync) begin             // CS asserted (low)
                    spi_state <= SPI_RECV;
                    bit_cnt   <= 0;
                    byte_idx  <= 0;
                    spi_shift <= 0;
                end
            end

            SPI_RECV: begin
                if (cs_sync) begin              // CS deasserted (high)
                    spi_state <= SPI_IDLE;
                end else if (sck_rising) begin
                    if (bit_cnt == 7) begin
                        bit_cnt   <= 0;
                        spi_shift <= 0;
                        if (byte_idx == 0) begin
                            spi_cmd  <= {spi_shift, mosi_r1};   // latch cmd byte
                            byte_idx <= 1;
                        end else begin
                            spi_data  <= {spi_shift, mosi_r1};  // latch data byte
                            cmd_valid <= 1;                     // both bytes ready
                            byte_idx  <= 0;
                        end
                    end else begin
                        spi_shift <= {spi_shift[5:0], mosi_r1};
                        bit_cnt   <= bit_cnt + 1;
                    end
                end
            end
        endcase
    end

    // ----------------------------------------------------------------
    // Sequencer state: note grid, playhead, cursor
    // ----------------------------------------------------------------

    reg [7:0] note_grid [0:15];  // note_grid[col] = 8-bit row mask (bit 0 = row 0)
    reg [3:0] playhead_col   = 0;
    reg       note_on_active = 0;
    reg [3:0] cursor_col     = 0;
    reg [2:0] cursor_row     = 0;

    // Power-on reset counter (done after 16 cycles)
    reg [4:0] rst_cnt  = 0;
    wire      rst_done = rst_cnt[4];

    // Single always block owns all note_grid writes (no multi-driver)
    always @(posedge CLK) begin
        if (!rst_done) begin
            // Clear all 16 columns one per clock cycle before accepting SPI
            note_grid[rst_cnt[3:0]] <= 8'b0;
            rst_cnt <= rst_cnt + 1;
        end else if (cmd_valid) begin
            // Process commands once both SPI bytes have been received
            if (spi_cmd[7]) begin               // NOTE_ON: 0x80 | step — advance playhead only
                playhead_col   <= spi_cmd[3:0];
                note_on_active <= 1;
            end else begin
                case (spi_cmd[6:5])
                    2'b11: begin                // GRID_UPDATE: 0x60 | col
                        note_grid[spi_cmd[3:0]] <= spi_data;
                    end
                    2'b10: begin                // CURSOR: 0x40 | row
                        cursor_row <= spi_cmd[2:0];
                        cursor_col <= spi_data[3:0];
                    end
                    default: begin              // NOTE_OFF: 0x00
                        note_on_active <= 0;
                    end
                endcase
            end
        end
    end

    wire is_playhead_cell;
    assign is_playhead_cell = in_grid && (cell_col == playhead_col);

    wire is_cursor_cell;
    assign is_cursor_cell = in_grid && (cell_col == cursor_col) && (cell_row == cursor_row);

    // these are the fakes notes actual notes will be added
    wire active_note = note_grid[cell_col][cell_row];

    // Make filled note
    wire inside_note_block;
    assign inside_note_block =
        in_grid &&
        active_note &&
        (cell_x > 6) &&
        (cell_x < CELL_W - 6) &&
        (cell_y > 5) &&
        (cell_y < CELL_H - 5);

        // the output with COLORS IGJEOIOIEVNAIOU

    always @(*) begin
        // Default black background
        LCD_R = 5'b00000;
        LCD_G = 6'b000000;
        LCD_B = 5'b00000;

        if (LCD_DEN) begin

            // Dark background
            LCD_R = 5'd1;
            LCD_G = 6'd1;
            LCD_B = 5'd2;

            if (in_grid) begin
                // Normal grid cell background
                LCD_R = 5'd2;
                LCD_G = 6'd3;
                LCD_B = 5'd5;

                // Playhead column highlight
                if (is_playhead_cell) begin
                    LCD_R = 5'd8;
                    LCD_G = 6'd8;
                    LCD_B = 5'd0;
                end

                // Cursor cell background (teal fill)
                if (is_cursor_cell) begin
                    LCD_R = 5'd0;
                    LCD_G = 6'd15;
                    LCD_B = 5'd20;
                end

                // Active note block
                if (inside_note_block) begin
                    LCD_R = 5'd31;
                    LCD_G = 6'd35;
                    LCD_B = 5'd0;
                end

                // Grid lines drawn on top
                if (is_grid_line) begin
                    LCD_R = 5'd18;
                    LCD_G = 6'd18;
                    LCD_B = 5'd18;
                end

                // Cursor cell outline (bright cyan — drawn over grid lines)
                if (is_cursor_cell && is_grid_line) begin
                    LCD_R = 5'd0;
                    LCD_G = 6'd50;
                    LCD_B = 5'd31;
                end
            end

            // White border around whole grid
            if (
                (x_counter >= GRID_X0 - 2) &&
                (x_counter <  GRID_X0 + GRID_W + 2) &&
                (y_counter >= GRID_Y0 - 2) &&
                (y_counter <  GRID_Y0 + GRID_H + 2) &&
                !in_grid
            ) begin
                LCD_R = 5'd31;
                LCD_G = 6'd63;
                LCD_B = 5'd31;
            end
        end
    end

    // ----------------------------------------------------------------
    // Audio Synthesis: square wave to passive piezo buzzer
    //
    // Row-to-note mapping (row 0 = top = highest pitch):
    //   Row 0: C5  Row 1: B4  Row 2: A4  Row 3: G4
    //   Row 4: F4  Row 5: E4  Row 6: D4  Row 7: C4
    // ----------------------------------------------------------------

    // Half-period lookup table (25 MHz clock cycles per half-period)
    function [15:0] note_half_period;
        input [2:0] row;
        case (row)
            3'd0: note_half_period = 16'd23900; // C5 = 523 Hz
            3'd1: note_half_period = 16'd25304; // B4 = 494 Hz
            3'd2: note_half_period = 16'd28409; // A4 = 440 Hz
            3'd3: note_half_period = 16'd31888; // G4 = 392 Hz
            3'd4: note_half_period = 16'd35817; // F4 = 349 Hz
            3'd5: note_half_period = 16'd37879; // E4 = 330 Hz
            3'd6: note_half_period = 16'd42517; // D4 = 294 Hz
            3'd7: note_half_period = 16'd47710; // C4 = 262 Hz
            default: note_half_period = 16'd0;
        endcase
    endfunction

    // Active rows for the current playhead column (from live note grid)
    wire [7:0] audio_mask = note_grid[playhead_col];

    // Priority encoder: pick the lowest active row
    reg [2:0] audio_row;
    reg       audio_active;
    always @(*) begin
        audio_row    = 3'd0;
        audio_active = 1'b0;
        if      (audio_mask[0]) begin audio_row = 3'd0; audio_active = 1'b1; end
        else if (audio_mask[1]) begin audio_row = 3'd1; audio_active = 1'b1; end
        else if (audio_mask[2]) begin audio_row = 3'd2; audio_active = 1'b1; end
        else if (audio_mask[3]) begin audio_row = 3'd3; audio_active = 1'b1; end
        else if (audio_mask[4]) begin audio_row = 3'd4; audio_active = 1'b1; end
        else if (audio_mask[5]) begin audio_row = 3'd5; audio_active = 1'b1; end
        else if (audio_mask[6]) begin audio_row = 3'd6; audio_active = 1'b1; end
        else if (audio_mask[7]) begin audio_row = 3'd7; audio_active = 1'b1; end
    end

    // Square wave generator state machine
    reg [15:0] buzz_cnt = 0;
    reg        buzz_out = 0;

    always @(posedge CLK) begin
        if (!audio_active || !note_on_active) begin
            // Silence: reset counter and hold output low
            buzz_cnt <= 0;
            buzz_out <= 0;
        end else begin
            if (buzz_cnt >= note_half_period(audio_row) - 1) begin
                buzz_cnt <= 0;
                buzz_out <= ~buzz_out;  // toggle every half-period
            end else begin
                buzz_cnt <= buzz_cnt + 1;
            end
        end
    end

    assign BUZZER = buzz_out;

endmodule
