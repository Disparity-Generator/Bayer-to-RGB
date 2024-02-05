library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;

entity RAW2RGB is
  generic (
    -- The fifo width has to be altered manually!!
    -- The approach of this component is to simply cut the surplus least significant bits away.
    -- This simulates bit shifting, thus the combining factor of the both widths has to be
    -- a power of 2!

    --! bits per color. FIFO (line_buffer) needs to get regenerated if this changes!
    G_INPUT_COLOR_WIDTH  : natural              := 12;

    --! width of each **color** in an output pixel
    G_RESULT_COLOR_WIDTH : natural              := 8;

    -- Mode 0: Buffer 1 = blue;    Buffer 2 = green 1; current_input_pixel = green 2; line_buffer = red
    -- Mode 1: Buffer 1 = green 2; Buffer 2 = red    ; current_input_pixel = blue   ; line_buffer = green 1
    -- Mode 2: Buffer 1 = green 1; Buffer 2 = blue   ; current_input_pixel = red    ; line_buffer = green 2
    -- Mode 3: Buffer 1 = red    ; Buffer 2 = green 2; current_input_pixel = green 1; line buffer = blue

    --! Sets the direction of the colors output by the camera
    --! 0: G1 - R | B - G2 (No mirroring)
    --! 1: R - G1 | G2 - B (Col mirroring)
    --! 2: B - G2 | G1 - R (Row mirroring)
    --! 3: G2 - B | R - G1 (Mirror both)
    G_MODE               : integer range 0 to 3 := 0;

    --! Decides if the output is colored or black and white. 
    --! "COLOR" for colored output, "GRAY" for black and white.
    G_COLOR_BW : string := "COLOR"
  );
  port (
    I_CLOCK                      : in    std_logic;

    --! Low-Active reset
    I_RESET_N                    : in    std_logic;

    --! input for currently active raw pixel
    I_PIXEL_RAW                  : in    std_logic_vector(G_INPUT_COLOR_WIDTH - 1 downto 0);

    --! Linevalid - indicates if we are in the active range of the row
    I_LVAL                       : in    std_logic;

    --! output for calculated pixel
    O_PIXEL_PROCESSED_FULL_WIDTH : out   std_logic_vector((3 * G_INPUT_COLOR_WIDTH) - 1 downto 0);

    --! output for calculated pixel with reduced width
    O_PIXEL_PROCESSED_DOWNSIZED  : out   std_logic_vector((3 * G_RESULT_COLOR_WIDTH) - 1 downto 0);

    --! indicates if the output contains a valid pixel
    O_PIXEL_OUT_VALID            : out   std_logic
  );
end entity RAW2RGB;

architecture RTL of RAW2RGB is

  constant c_right_output_border      : integer := G_INPUT_COLOR_WIDTH - G_RESULT_COLOR_WIDTH;

  signal w_line_buffer_data           : std_logic_vector(G_INPUT_COLOR_WIDTH - 1 downto 0);
  signal w_line_buffer_q              : std_logic_vector(G_INPUT_COLOR_WIDTH - 1 downto 0);
  signal w_line_buffer_read_request   : std_logic;
  signal w_line_buffer_write_request  : std_logic;
  signal w_line_buffer_empty          : std_logic;
  signal w_line_buffer_full           : std_logic;
  signal w_line_buffer_usedw          : std_logic_vector(G_INPUT_COLOR_WIDTH - 1 downto 0);
  signal w_line_buffer_q_unsigned     : std_logic_vector(G_INPUT_COLOR_WIDTH - 1 downto 0);
  signal w_line_buffer_aclr           : std_logic;
  signal w_line_buffer_sclr           : std_logic;

  type t_states is (WAIT_FOR_NEW_LINE, BUFFER_LINE, PROCESS_FIRST_COLUMN, PROCESS_SECOND_COLUMN); -- states of the state machine

  signal w_next_state                 : t_states;
  signal r_current_state              : t_states := WAIT_FOR_NEW_LINE;

  type t_actions is (BUFFER_LINE, PROCESS_PIXEL);

  signal w_latest_action              : t_actions;
  signal r_latest_action              : t_actions := process_pixel;

  -- The sum of the green is potentially on bit

  -- We need to combine four pixels, distributed on two lines, thus some of them need to be cached. 
  -- The color stored in a buffer depends on the chosen mode. 
  signal w_buffer_2                   : std_logic_vector(G_INPUT_COLOR_WIDTH - 1 downto 0);
  signal w_buffer_1                   : std_logic_vector(G_INPUT_COLOR_WIDTH - 1 downto 0);
  signal r_buffer_2                   : std_logic_vector(G_INPUT_COLOR_WIDTH - 1 downto 0) := (others => '0');
  signal r_buffer_1                   : std_logic_vector(G_INPUT_COLOR_WIDTH - 1 downto 0) := (others => '0');

  -- Each camera pixel consists of 3*12 bits = 36 bits.
  -- We probably have to divide it down since we mostly want to work with 4 or 8 bits per color

  -- The state machine consists of two states.
  -- The first line needs to get buffered completely.
  -- Afer that we parallely walk through the buffered line and the second line output from the camera
  -- to finish the calculation the pixel

  signal r_lval_low_capture : std_logic;
  signal r_capture_input_pixel_low        : std_logic_vector(G_INPUT_COLOR_WIDTH - 1 downto 0) := (others => '0');

  signal r_current_input_pixel_delay        : std_logic_vector(G_INPUT_COLOR_WIDTH - 1 downto 0) := (others => '0');
  signal r_current_input_pixel        : std_logic_vector(G_INPUT_COLOR_WIDTH - 1 downto 0) := (others => '0');
  signal r_lval : std_logic;

  signal w_pixel_processed_full_width : std_logic_vector((3 * G_INPUT_COLOR_WIDTH) - 1 downto 0);
  signal w_pixel_processed_downsized  : std_logic_vector((3 * G_RESULT_COLOR_WIDTH) - 1 downto 0);
  signal w_pixel_out_valid            : std_logic;

  signal r_pixel_processed_full_width : std_logic_vector((3 * G_INPUT_COLOR_WIDTH) - 1 downto 0)  := (others => '0');
  signal r_pixel_processed_downsized  : std_logic_vector((3 * G_RESULT_COLOR_WIDTH) - 1 downto 0) := (others => '0');
  signal r_pixel_out_valid            : std_logic                                                 := '0';

  signal w_buffer_reset : std_logic;

  component LINE_BUFFER is
    port (
      CLOCK : in    std_logic;
      DATA  : in    std_logic_vector(G_INPUT_COLOR_WIDTH - 1 downto 0);
      RDREQ : in    std_logic;
      WRREQ : in    std_logic;
      EMPTY : out   std_logic;
      FULL  : out   std_logic;
      Q     : out   std_logic_vector(G_INPUT_COLOR_WIDTH - 1 downto 0);
      ACLR  : in    std_logic;
      SCLR  : in    std_logic;
      USEDW : out   std_logic_vector(G_INPUT_COLOR_WIDTH - 1 downto 0)
    );
  end component line_buffer;

begin

  -- Because the values of one pixel are distributed over two lines, we have to buffer one complete line.
  -- Using a TRDB-5M camera this means that we have to store 2095 pixels at most (using HD mode).
  -- The buffer length has to be a power to the base two, thus the real length is up to 4095.
  -- As mentioned earlier: If the source pixel width changes, the buffer width must change accordingly.
  -- This doesn't happen automatically based on the generic!
  U0 : LINE_BUFFER
    port map (
      CLOCK => I_CLOCK,
      DATA  => w_line_buffer_data,
      RDREQ => w_line_buffer_read_request,
      WRREQ => w_line_buffer_write_request,
      EMPTY => w_line_buffer_empty,
      FULL  => w_line_buffer_full,
      Q     => w_line_buffer_q,
      ACLR  => w_buffer_reset,
      -- ACLR  => w_line_buffer_aclr,
      SCLR  => '0',
      USEDW => w_line_buffer_usedw
    );

  -------------------
  -- State machine --
  -------------------

  w_buffer_reset <= not I_RESET_N;

  RAW2RGB : process (r_current_state, r_lval, r_current_input_pixel, w_line_buffer_q, r_latest_action, r_buffer_2, r_buffer_1) is
  begin

    case(r_current_state) is

      -- When lval is low, that means we have no active pixel and have to wait for a new line before we can proceed.
      when WAIT_FOR_NEW_LINE =>

        if (r_lval = '1') then
          w_line_buffer_sclr <= '0';
          -- If we recently buffered a line, the next action will be the processing of the final pixel.
          -- If we recently processed pixels, we have to buffer again.
          if (r_latest_action = BUFFER_LINE) then
            w_next_state <= PROCESS_FIRST_COLUMN;
          else
            w_next_state <= BUFFER_LINE;
          end if;
        else
          w_next_state <= WAIT_FOR_NEW_LINE;
        end if;

        w_pixel_out_valid           <= '0';
        w_line_buffer_read_request  <= '0';
        w_latest_action             <= r_latest_action;
        w_line_buffer_write_request <= '0';

      -- Since we combine two lines to one, we have to completely buffer the first line.
      when BUFFER_LINE =>

        w_latest_action            <= BUFFER_LINE;
        w_pixel_out_valid          <= '0';
        w_line_buffer_read_request <= '0';

        -- We assume that the FIFO is long enough to store a whole line, thus there is no flow control!
        w_line_buffer_write_request <= '1';

        -- as long as we get valid pixels, we keep buffering
        if (r_lval = '1') then
          w_next_state <= BUFFER_LINE;
        else
          w_next_state <= WAIT_FOR_NEW_LINE;
        end if;

      -- Each pixel is a combined value from four values, distributed in two lines and two columns.
      -- The first line is buffered in the FIFO, the second line is processed while it is output from the camera.
      -- The final calculation of one pixel needs two cycles.
      -- While we are in the first cycle, the colors (green 1 and blue) are buffered.
      -- While we are in the second line, the final pixel is built:
      -- Blue from the buffer and red from the current output are copied directly into the target pixel.
      -- Green is built by calculating the mean value of the buffered green 1 value and the green 2 at the current output.

      when PROCESS_FIRST_COLUMN =>

        w_next_state                <= PROCESS_SECOND_COLUMN;
        w_latest_action             <= process_pixel;
        w_pixel_out_valid           <= '0';
        w_line_buffer_write_request <= '0';
        w_line_buffer_read_request  <= '1';

      when PROCESS_SECOND_COLUMN =>

        if (r_lval = '1') then
          w_next_state <= PROCESS_FIRST_COLUMN;
        else
          w_next_state <= WAIT_FOR_NEW_LINE;
        end if;

        w_latest_action             <= process_pixel;
        w_line_buffer_read_request  <= '1';
        w_line_buffer_write_request <= '0';
        w_pixel_out_valid           <= '1';

    end case;

  end process RAW2RGB;

  PROC_STATE_FF : process (I_CLOCK, I_RESET_N) is
  begin

    if (I_RESET_N = '0') then
      r_current_state <= wait_for_new_line;
    elsif (rising_edge(I_CLOCK)) then
      r_current_state <= w_next_state;
    end if;

  end process PROC_STATE_FF;

  ---------------
  -- Registers --
  ---------------

  -- We have to delay the input by one clock because
  -- we enter the buffer or processing state one clock late.

  PROC_INPUT_FF : process (I_RESET_N, I_CLOCK) is
  begin

    if (I_RESET_N = '0') then
      r_current_input_pixel <= (others => '0');
      r_current_input_pixel_delay <= (others => '0');
      -- r_lval <= '0';
    elsif (rising_edge(I_CLOCK)) then
      -- Delay pixel by one more clock cycle because we would lose the 
      -- first one in a new row
      r_current_input_pixel_delay <= I_PIXEL_RAW;
      r_current_input_pixel <= r_current_input_pixel_delay;
		  r_lval <= I_LVAL;
      -- r_current_input_pixel <= I_PIXEL_RAW;
    end if;
    
  end process PROC_INPUT_FF;


  -- Mode 0: Buffer 1 = blue;    Buffer 2 = green 1
  -- Mode 1: Buffer 1 = green 2; Buffer 2 = red
  -- Mode 2: Buffer 1 = green 1; Buffer 2 = blue
  -- Mode 3: Buffer 1 = red    ; Buffer 2 = green 2
  PROC_COLOR_REGISTERS : process (I_RESET_N, I_CLOCK) is
  begin

    if (I_RESET_N = '0') then
      r_buffer_1 <= (others => '0');
      r_buffer_2 <= (others => '0');
    elsif (rising_edge(I_CLOCK)) then
      if (r_current_state = process_first_column) then
        r_buffer_1 <= w_buffer_1;
        r_buffer_2 <= w_buffer_2;
      end if;
    end if;

  end process PROC_COLOR_REGISTERS;

  PROC_OUTPUT_REGISTERS : process (I_RESET_N, I_CLOCK) is
  begin

    if (I_RESET_N = '0') then
      r_pixel_processed_downsized  <= (others => '0');
      r_pixel_processed_full_width <= (others => '0');
    elsif (rising_edge(I_CLOCK)) then
      r_pixel_processed_downsized  <= w_pixel_processed_downsized;
      r_pixel_processed_full_width <= w_pixel_processed_full_width;
    end if;

  end process PROC_OUTPUT_REGISTERS;

  PROC_VALID_FF : process (I_RESET_N, I_CLOCK) is
  begin

    if (I_RESET_N = '0') then
      r_pixel_out_valid <= '0';
    elsif (rising_edge(I_CLOCK)) then
      r_pixel_out_valid <= w_pixel_out_valid;
    end if;

  end process PROC_VALID_FF;

  PROC_LATEST_ACTION_FF : process (I_RESET_N, I_CLOCK) is
  begin

    if (I_RESET_N = '0') then
      r_latest_action <= process_pixel;
    elsif (rising_edge(I_CLOCK)) then
      r_latest_action <= w_latest_action;
    end if;

  end process PROC_LATEST_ACTION_FF;

  ----------------------------
  -- Wires to the registers --
  ----------------------------

  -- Input to the register that delays the input pixel by one cycle.
  w_line_buffer_data <= r_current_input_pixel;

  -- The blue pixel is in the camera stream, but only if we are in the first column.
  -- This wire is the input to the corresponding register. The register's enable is based on the current column.
  w_buffer_1 <= std_logic_vector(r_current_input_pixel);

  -- The first green pixel is in the buffer output, but only if we are in the first column.
  -- This wire is the input to the corresponding register. The register's enable is based on the current column.
  w_buffer_2 <= w_line_buffer_q;

  -----------------------------------
  -- Wires to the output registers --
  -----------------------------------

  color_mode : if G_COLOR_BW = "COLOR" generate

  PROC_BUILD_PIXEL : process (w_line_buffer_q, r_buffer_2, r_current_input_pixel, r_buffer_1) is
  begin

    case G_MODE is

      when 0 =>

        -- Since it's not allowed to slice after an operation like (a + b)(5 downto 1), we have to use a work around.
        -- To slice the green pixel, another syntax is used with the same effect.
        w_pixel_processed_full_width <= w_line_buffer_q
                                        & std_logic_vector("+"(unsigned('0' & r_buffer_2), (unsigned('0' & r_current_input_pixel)))(G_INPUT_COLOR_WIDTH downto 1))
                                        & r_buffer_1;

        -- The target pixel width is most certainly not 12 bit wide, thus we scale the result down
        -- We can't divide the whole pixel value because the color would change,
        -- we have to use scale down on each pixel seperately.
        -- Since it's not allowed to slice after an operation like (a + b)(5 downto 1), we have to use a work around.
        -- To slice the green pixel, another syntax is used with the same effect but we have to slice one bit earlier
        -- because due to the addition, the result is one bit wider.
        w_pixel_processed_downsized <= w_line_buffer_q(G_INPUT_COLOR_WIDTH - 1 downto c_right_output_border)
                                       & std_logic_vector("+"(unsigned('0' & r_buffer_2), (unsigned('0' & r_current_input_pixel)))(G_INPUT_COLOR_WIDTH downto c_right_output_border + 1))
                                       & r_buffer_1(G_INPUT_COLOR_WIDTH - 1 downto c_right_output_border);

      when 1 =>

        -- Since it's not allowed to slice after an operation like (a + b)(5 downto 1), we have to use a work around.
        -- To slice the green pixel, another syntax is used with the same effect.
        w_pixel_processed_full_width <= r_buffer_2
                                        & std_logic_vector("+"(unsigned('0' & w_line_buffer_q), (unsigned('0' & r_buffer_1)))(G_INPUT_COLOR_WIDTH downto 1))
                                        & r_current_input_pixel;

        -- The target pixel width is most certainly not 12 bit wide, thus we scale the result down
        -- We can't divide the whole pixel value because the color would change,
        -- we have to use scale down on each pixel seperately.
        -- Since it's not allowed to slice after an operation like (a + b)(5 downto 1), we have to use a work around.
        -- To slice the green pixel, another syntax is used with the same effect but we have to slice one bit earlier
        -- because due to the addition, the result is one bit wider.
        w_pixel_processed_downsized <= r_buffer_2(G_INPUT_COLOR_WIDTH - 1 downto c_right_output_border)
                                       & std_logic_vector("+"(unsigned('0' & w_line_buffer_q), (unsigned('0' & r_buffer_1)))(G_INPUT_COLOR_WIDTH downto c_right_output_border + 1))
                                       & r_current_input_pixel(G_INPUT_COLOR_WIDTH - 1 downto c_right_output_border);

      when 2 =>

        -- Since it's not allowed to slice after an operation like (a + b)(5 downto 1), we have to use a work around.
        -- To slice the green pixel, another syntax is used with the same effect.
        w_pixel_processed_full_width <= r_current_input_pixel
                                        & std_logic_vector("+"(unsigned('0' & r_buffer_1), (unsigned('0' & w_line_buffer_q)))(G_INPUT_COLOR_WIDTH downto 1))
                                        & r_buffer_2;

        -- The target pixel width is most certainly not 12 bit wide, thus we scale the result down
        -- We can't divide the whole pixel value because the color would change,
        -- we have to use scale down on each pixel seperately.
        -- Since it's not allowed to slice after an operation like (a + b)(5 downto 1), we have to use a work around.
        -- To slice the green pixel, another syntax is used with the same effect but we have to slice one bit earlier
        -- because due to the addition, the result is one bit wider.
        w_pixel_processed_downsized <= r_current_input_pixel(G_INPUT_COLOR_WIDTH - 1 downto c_right_output_border)
                                       & std_logic_vector("+"(unsigned('0' & r_buffer_1), (unsigned('0' & w_line_buffer_q)))(G_INPUT_COLOR_WIDTH downto c_right_output_border + 1))
                                       & r_buffer_2(G_INPUT_COLOR_WIDTH - 1 downto c_right_output_border);

      when 3 =>

        -- Since it's not allowed to slice after an operation like (a + b)(5 downto 1), we have to use a work around.
        -- To slice the green pixel, another syntax is used with the same effect.
        w_pixel_processed_full_width <= r_buffer_1
                                        & std_logic_vector("+"(unsigned('0' & r_current_input_pixel), (unsigned('0' & r_buffer_2)))(G_INPUT_COLOR_WIDTH downto 1))
                                        & w_line_buffer_q;

        -- The target pixel width is most certainly not 12 bit wide, thus we scale the result down
        -- We can't divide the whole pixel value because the color would change,
        -- we have to use scale down on each pixel seperately.
        -- Since it's not allowed to slice after an operation like (a + b)(5 downto 1), we have to use a work around.
        -- To slice the green pixel, another syntax is used with the same effect but we have to slice one bit earlier
        -- because due to the addition, the result is one bit wider.
        w_pixel_processed_downsized <= r_buffer_1(G_INPUT_COLOR_WIDTH - 1 downto c_right_output_border)
                                       & std_logic_vector("+"(unsigned('0' & r_current_input_pixel), (unsigned('0' & w_line_buffer_q)))(G_INPUT_COLOR_WIDTH downto c_right_output_border + 1))
                                       & w_line_buffer_q(G_INPUT_COLOR_WIDTH - 1 downto c_right_output_border);

    end case;

  end process PROC_BUILD_PIXEL;

end generate;

  gray_mode : if G_COLOR_BW = "GRAY" generate
    PROC_BUILD_PIXEL : process (w_line_buffer_q, r_buffer_2, r_current_input_pixel, r_buffer_1) is
      variable v_r1 : unsigned(G_INPUT_COLOR_WIDTH - 1 downto 0);
      variable v_r2 : unsigned(G_INPUT_COLOR_WIDTH - 1 downto 0);
      variable v_g1 : unsigned(G_INPUT_COLOR_WIDTH - 1 downto 0);
      variable v_g2 : unsigned(G_INPUT_COLOR_WIDTH - 1 downto 0);
      variable v_b1 : unsigned(G_INPUT_COLOR_WIDTH - 1 downto 0);
      variable v_b2 : unsigned(G_INPUT_COLOR_WIDTH - 1 downto 0);

      variable v_result : unsigned(G_INPUT_COLOR_WIDTH - 1 downto 0);
    begin
  
      case G_MODE is
  
        when 0 =>
  
          v_r1 := "00" & unsigned(w_line_buffer_q(G_INPUT_COLOR_WIDTH - 1 downto 2));
          v_r2 := "00000" & unsigned(w_line_buffer_q(G_INPUT_COLOR_WIDTH - 1 downto 5));
          
          v_g1 := "0" & "+"(unsigned('0' & r_buffer_2), (unsigned('0' & r_current_input_pixel)))(G_INPUT_COLOR_WIDTH downto 2);
          v_g2 := "0000" & "+"(unsigned('0' & r_buffer_2), (unsigned('0' & r_current_input_pixel)))(G_INPUT_COLOR_WIDTH downto 5);

          v_b1 := "000" & unsigned(r_buffer_1(G_INPUT_COLOR_WIDTH - 1 downto 3));
          v_b2 := "00000" & unsigned(r_buffer_1(G_INPUT_COLOR_WIDTH - 1 downto 5));

  
        when 1 =>
          v_r1 := "00" & unsigned(r_buffer_2(G_INPUT_COLOR_WIDTH - 1 downto 2));
          v_r2 := "00000" & unsigned(r_buffer_2(G_INPUT_COLOR_WIDTH - 1 downto 5));
          
          v_g1 := "0" & "+"(unsigned('0' & w_line_buffer_q), (unsigned('0' & r_buffer_1)))(G_INPUT_COLOR_WIDTH downto 2);
          v_g2 := "0000" & "+"(unsigned('0' & w_line_buffer_q), (unsigned('0' & r_buffer_1)))(G_INPUT_COLOR_WIDTH downto 5);

          v_b1 := "000" & unsigned(r_current_input_pixel(G_INPUT_COLOR_WIDTH - 1 downto 3));
          v_b2 := "00000" & unsigned(r_current_input_pixel(G_INPUT_COLOR_WIDTH - 1 downto 5));
  
        when 2 =>
          v_r1 := "00" & unsigned(r_current_input_pixel(G_INPUT_COLOR_WIDTH - 1 downto 2));
          v_r2 := "00000" & unsigned(r_current_input_pixel(G_INPUT_COLOR_WIDTH - 1 downto 5));
          
          v_g1 := "0" & "+"(unsigned('0' & r_buffer_1), (unsigned('0' & w_line_buffer_q)))(G_INPUT_COLOR_WIDTH downto 2);
          v_g2 := "0000" & "+"(unsigned('0' & r_buffer_1), (unsigned('0' & w_line_buffer_q)))(G_INPUT_COLOR_WIDTH downto 5);

          v_b1 := "000" & unsigned(r_buffer_2(G_INPUT_COLOR_WIDTH - 1 downto 3));
          v_b2 := "00000" & unsigned(r_buffer_2(G_INPUT_COLOR_WIDTH - 1 downto 5));
  
        when 3 =>
          v_r1 := "00" & unsigned(r_buffer_1(G_INPUT_COLOR_WIDTH - 1 downto 2));
          v_r2 := "00000" & unsigned(r_buffer_1(G_INPUT_COLOR_WIDTH - 1 downto 5));
          
          v_g1 := "0" & "+"(unsigned('0' & r_current_input_pixel), (unsigned('0' & w_line_buffer_q)))(G_INPUT_COLOR_WIDTH downto 2);
          v_g2 := "0000" & "+"(unsigned('0' & r_current_input_pixel), (unsigned('0' & w_line_buffer_q)))(G_INPUT_COLOR_WIDTH downto 5);

          v_b1 := "000" & unsigned(w_line_buffer_q(G_INPUT_COLOR_WIDTH - 1 downto c_right_output_border + 3));
          v_b2 := "00000" & unsigned(w_line_buffer_q(G_INPUT_COLOR_WIDTH - 1 downto c_right_output_border + 5));
  
      end case;
      v_result := v_r1 + v_r2 + v_g1 + v_g2 + v_b1 + v_b2;

      w_pixel_processed_downsized <= std_logic_vector(v_result(G_INPUT_COLOR_WIDTH - 1 downto c_right_output_border) & v_result(G_INPUT_COLOR_WIDTH - 1 downto c_right_output_border) & v_result(G_INPUT_COLOR_WIDTH - 1 downto c_right_output_border));
      w_pixel_processed_full_width <= std_logic_vector(v_result & v_result & v_result);
  
    end process PROC_BUILD_PIXEL;
  end generate;

  ----------------------------------------------------------
  -- Connections between output ports and registers/wires --
  ----------------------------------------------------------
  O_PIXEL_PROCESSED_FULL_WIDTH <= r_pixel_processed_full_width;
  O_PIXEL_PROCESSED_DOWNSIZED  <= r_pixel_processed_downsized;
  O_PIXEL_OUT_VALID            <= r_pixel_out_valid;

end architecture RTL;
