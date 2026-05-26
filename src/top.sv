module top (
    input  wire CLK,

    output wire LCD_CLK,
    output wire LCD_DEN,

    output reg [4:0] LCD_R,
    output reg [5:0] LCD_G,
    output reg [4:0] LCD_B
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


    reg [24:0] playhead_counter = 0;
    reg [3:0] playhead_col = 0;

    // Adjust this number to change playhead speed th ebigger the numebr  slower
    localparam PLAYHEAD_SPEED = 25'd12_500_000;

    always @(posedge CLK) begin
        if (playhead_counter >= PLAYHEAD_SPEED) begin
            playhead_counter <= 0;

            if (playhead_col == 15)
                playhead_col <= 0;
            else
                playhead_col <= playhead_col + 1;
        end else begin
            playhead_counter <= playhead_counter + 1;
        end
    end

    wire is_playhead_cell;3
    assign is_playhead_cell = in_grid && (cell_col == playhead_col);

    // these are the fakes notes actual notes will be added
    reg active_note;

    always @(*) begin
        active_note = 1'b0;

        case (cell_row)
            3'd0: begin
                if (cell_col == 0 || cell_col == 4 || cell_col == 8 || cell_col == 12)
                    active_note = 1'b1;
            end

            3'd1: begin
                if (cell_col == 2 || cell_col == 6 || cell_col == 10 || cell_col == 14)
                    active_note = 1'b1;
            end

            3'd2: begin
                if (cell_col == 1 || cell_col == 5 || cell_col == 9 || cell_col == 13)
                    active_note = 1'b1;
            end

            3'd4: begin
                if (cell_col == 0 || cell_col == 8)
                    active_note = 1'b1;
            end

            3'd6: begin
                if (cell_col == 3 || cell_col == 7 || cell_col == 11 || cell_col == 15)
                    active_note = 1'b1;
            end

            default: begin
                active_note = 1'b0;
            end
        endcase
    end

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

endmodule