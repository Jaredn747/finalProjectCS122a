module top (
    input  wire CLK,
    input  wire SPI_SCK,
    input  wire SPI_MOSI,
    input  wire SPI_CS,
    output wire LCD_CLK,
    output wire LCD_DEN,
    output reg [4:0] LCD_R,
    output reg [5:0] LCD_G,
    output reg [4:0] LCD_B,
    output wire BUZZER
);

    assign LCD_CLK = CLK;

    // LCD pixel scanner
    localparam H_ACTIVE = 480, H_TOTAL = 525;
    localparam V_ACTIVE = 272, V_TOTAL = 285;

    reg [9:0] x = 0, y = 0;

    always @(posedge CLK) begin
        if (x == H_TOTAL - 1) begin
            x <= 0;
            y <= (y == V_TOTAL - 1) ? 0 : y + 1;
        end else
            x <= x + 1;
    end

    assign LCD_DEN = (x < H_ACTIVE) && (y < V_ACTIVE);

    // Grid layout
    localparam COLS = 16, ROWS = 8;
    localparam X0 = 16,   Y0 = 32;
    localparam CW = 28,   CH = 24;
    localparam GW = COLS * CW, GH = ROWS * CH;

    wire        in_grid = (x >= X0) && (x < X0+GW) && (y >= Y0) && (y < Y0+GH);
    wire [9:0]  gx = x - X0,  gy = y - Y0;
    wire [3:0]  col = gx / CW;
    wire [2:0]  row = gy / CH;
    wire [9:0]  cx  = gx % CW, cy = gy % CH;
    wire        is_border = in_grid && (cx==0 || cy==0 || cx==CW-1 || cy==CH-1);

    // SPI input
    reg sck0=0, sck1=0, sck2=0;
    reg cs0=0,  cs1=0;
    reg mosi0=0, mosi1=0;

    always @(posedge CLK) begin
        {sck2, sck1, sck0} <= {sck1, sck0, SPI_SCK};
        {cs1,  cs0}        <= {cs0,  SPI_CS};
        {mosi1,mosi0}      <= {mosi0,SPI_MOSI};
    end

    wire sck_rise = sck1 && !sck2;
    wire cs       = cs1;

    // SPI Receiver

    localparam SPI_IDLE = 1'b0;
    localparam SPI_RECV = 1'b1;

    reg       spi_state = SPI_IDLE;
    reg [6:0] shift     = 0;
    reg [2:0] bit_cnt   = 0;
    reg       byte_idx  = 0;
    reg [7:0] spi_cmd   = 0;
    reg [7:0] spi_data  = 0;
    reg       cmd_valid = 0;

    always @(posedge CLK) begin
        cmd_valid <= 0;
        case (spi_state)

            SPI_IDLE:
                if (!cs) begin
                    spi_state <= SPI_RECV;
                    bit_cnt <= 0;  byte_idx <= 0;  shift <= 0;
                end

            SPI_RECV:
                if (cs)
                    spi_state <= SPI_IDLE;
                else if (sck_rise) begin
                    if (bit_cnt == 7) begin
                        bit_cnt <= 0;  shift <= 0;
                        if (!byte_idx) begin
                            spi_cmd  <= {shift, mosi1};
                            byte_idx <= 1;
                        end else begin
                            spi_data  <= {shift, mosi1};
                            cmd_valid <= 1;
                            byte_idx  <= 0;
                        end
                    end else begin
                        shift   <= {shift[5:0], mosi1};
                        bit_cnt <= bit_cnt + 1;
                    end
                end

        endcase
    end
 
    //  Command Decoder
 
    reg [7:0] note_grid [0:15];
    reg [3:0] playhead  = 0;
    reg [3:0] cur_col   = 0;
    reg [2:0] cur_row   = 0;
    reg       note_on   = 0;

    reg [4:0] rst_cnt = 0;
    wire      rst_done = rst_cnt[4];

    always @(posedge CLK) begin
        if (!rst_done) begin
            note_grid[rst_cnt[3:0]] <= 8'b0;
            rst_cnt <= rst_cnt + 1;
        end else if (cmd_valid) begin
            if (spi_cmd[7]) begin
                playhead <= spi_cmd[3:0];
                note_on  <= 1;
            end else begin
                case (spi_cmd[6:5])
                    2'b11:   note_grid[spi_cmd[3:0]] <= spi_data;
                    2'b10:   begin cur_row <= spi_cmd[2:0]; cur_col <= spi_data[3:0]; end
                    default: note_on <= 0;
                endcase
            end
        end
    end

    // Display
    wire is_playhead = in_grid && (col == playhead);
    wire is_cursor   = in_grid && (col == cur_col) && (row == cur_row);
    wire has_note    = note_grid[col][row];
    wire note_block  = in_grid && has_note && (cx>6) && (cx<CW-6) && (cy>5) && (cy<CH-5);

    always @(*) begin
        LCD_R = 0; LCD_G = 0; LCD_B = 0;

        if (LCD_DEN) begin
            LCD_R = 5'd1;  LCD_G = 6'd1;  LCD_B = 5'd2;           // background

            if (in_grid) begin
                LCD_R = 5'd2;  LCD_G = 6'd3;  LCD_B = 5'd5;       // grid cell

                if (is_playhead) begin LCD_R = 5'd8;  LCD_G = 6'd8;  LCD_B = 5'd0;  end
                if (is_cursor)   begin LCD_R = 5'd0;  LCD_G = 6'd15; LCD_B = 5'd20; end
                if (note_block)  begin LCD_R = 5'd31; LCD_G = 6'd35; LCD_B = 5'd0;  end
                if (is_border)   begin LCD_R = 5'd18; LCD_G = 6'd18; LCD_B = 5'd18; end
                if (is_cursor && is_border) begin LCD_R = 5'd0; LCD_G = 6'd50; LCD_B = 5'd31; end
            end

            if ((x>=X0-2) && (x<X0+GW+2) && (y>=Y0-2) && (y<Y0+GH+2) && !in_grid)
                begin LCD_R = 5'd31; LCD_G = 6'd63; LCD_B = 5'd31; end  // border
        end
    end

    // Audio Square Wave Generator
 
    function [15:0] half_period;
        input [2:0] r;
        case (r)
            3'd0: half_period = 16'd23900;  // C5
            3'd1: half_period = 16'd25304;  // B4
            3'd2: half_period = 16'd28409;  // A4
            3'd3: half_period = 16'd31888;  // G4
            3'd4: half_period = 16'd35817;  // F4
            3'd5: half_period = 16'd37879;  // E4
            3'd6: half_period = 16'd42517;  // D4
            3'd7: half_period = 16'd47710;  // C4
            default: half_period = 16'd0;
        endcase
    endfunction

    wire [7:0] audio_mask = note_grid[playhead];

    reg [2:0] audio_row;
    reg       audio_active;
    always @(*) begin
        audio_row = 0; audio_active = 0;
        if      (audio_mask[0]) begin audio_row = 0; audio_active = 1; end
        else if (audio_mask[1]) begin audio_row = 1; audio_active = 1; end
        else if (audio_mask[2]) begin audio_row = 2; audio_active = 1; end
        else if (audio_mask[3]) begin audio_row = 3; audio_active = 1; end
        else if (audio_mask[4]) begin audio_row = 4; audio_active = 1; end
        else if (audio_mask[5]) begin audio_row = 5; audio_active = 1; end
        else if (audio_mask[6]) begin audio_row = 6; audio_active = 1; end
        else if (audio_mask[7]) begin audio_row = 7; audio_active = 1; end
    end

    localparam AUDIO_IDLE   = 1'b0;
    localparam AUDIO_ACTIVE = 1'b1;

    reg        audio_state = AUDIO_IDLE;
    reg [15:0] buzz_cnt    = 0;
    reg        buzz_out    = 0;

    always @(posedge CLK) begin
        case (audio_state)

            AUDIO_IDLE:
                if (audio_active && note_on) begin
                    audio_state <= AUDIO_ACTIVE;
                    buzz_cnt <= 0;
                    buzz_out <= 0;
                end

            AUDIO_ACTIVE:
                if (!audio_active || !note_on) begin
                    audio_state <= AUDIO_IDLE;
                    buzz_cnt <= 0;
                    buzz_out <= 0;
                end else if (buzz_cnt >= half_period(audio_row) - 1) begin
                    buzz_cnt <= 0;
                    buzz_out <= ~buzz_out;
                end else
                    buzz_cnt <= buzz_cnt + 1;

        endcase
    end

    assign BUZZER = buzz_out;

endmodule
