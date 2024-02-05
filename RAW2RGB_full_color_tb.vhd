library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;
  use std.textio.all;
  use ieee.std_logic_textio.all;

entity RAW2RGB_FULL_COLOR_TB is -- keine Schnittstellen
end entity RAW2RGB_FULL_COLOR_TB;

architecture ARCH of RAW2RGB_FULL_COLOR_TB is

  signal clk_pixel_s                                          : std_logic;
  signal reset_n_s                                            : std_logic;
  signal pixel_in_s                                           : std_logic_vector(11 downto 0);
  signal lval_s                                               : std_logic;
  signal r_lval                                               : std_logic;

  signal pixel_out_s                                          : std_logic_vector(35 downto 0);
  signal pixel_out_reduced_size_s                             : std_logic_vector(23 downto 0);
  signal pixel_out_valid_s                                    : std_logic;

  signal pixel_out_red_s                                      : std_logic_vector(11 downto 0);
  signal pixel_out_green_s                                    : std_logic_vector(11 downto 0);
  signal pixel_out_blue_s                                     : std_logic_vector(11 downto 0);

  signal pixel_out_red_reduced_s                              : std_logic_vector(7 downto 0);
  signal pixel_out_green_reduced_s                            : std_logic_vector(7 downto 0);
  signal pixel_out_blue_reduced_s                             : std_logic_vector(7 downto 0);

  component RAW2RGB is
    generic (
      -- The fifo width has to be altered manually!!
      G_INPUT_COLOR_WIDTH  : natural := 12;
      G_RESULT_COLOR_WIDTH : natural := 8;
      G_MODE : integer := 0
    );
    port (
      I_CLOCK                      : in    std_logic;
      I_RESET_N                    : in    std_logic;
      I_PIXEL_RAW                  : in    std_logic_vector(G_INPUT_COLOR_WIDTH - 1 downto 0);
      I_LVAL                       : in    std_logic;

      O_PIXEL_PROCESSED_FULL_WIDTH : out   std_logic_vector((3 * G_INPUT_COLOR_WIDTH) - 1 downto 0);
      O_PIXEL_PROCESSED_DOWNSIZED  : out   std_logic_vector((3 * G_RESULT_COLOR_WIDTH) - 1 downto 0);
      O_PIXEL_OUT_VALID            : out   std_logic
    );
  end component raw2rgb;

  procedure discard_separator (
    variable line_pointer : inout line
  ) is

    variable dump : string(1 to 1);

  begin

    read(line_pointer, dump);

  end procedure;

  procedure get_integer (
    variable line_pointer : inout line;
    signal int_out        : out integer) is

    variable v_int_out           : integer;
    variable v_separator_discard : string(1 to 1);

  begin

    read(line_pointer, v_int_out);
    int_out <= v_int_out;
    discard_separator(line_pointer);

  end procedure;

  procedure get_integer (
    variable line_pointer : inout line;
    signal int_out        : out std_logic_vector) is

    variable v_int_out           : integer;
    variable v_separator_discard : string(1 to 1);

  begin

    read(line_pointer, v_int_out);
    int_out <= std_logic_vector(to_unsigned(v_int_out, int_out'length));
    discard_separator(line_pointer);

  end procedure;

  -- Ports in Richtung nutzende Komponente
  signal clk_tb_s                                             : std_logic;
  signal w_reset_n                                            : std_logic;
  signal w_write_enable                                       : std_logic;
  signal w_ready                                              : std_logic;

  signal r_pixel                                              : std_logic_vector(11 downto 0);

  constant c_image_width                                      : integer := 1280;
  constant c_image_height                                     : integer := 960;

  constant c_result_image_width                               : integer := c_image_width / 2;
  constant c_result_image_height                              : integer := c_image_height / 2;

  constant c_minimal_disparity                                : integer := 40;
  constant c_maximum_disparity                                : integer := 80;

  type out_memory is ARRAY (0 to c_result_image_height - 1, 0 to c_result_image_width - 1) of std_logic_vector(23 downto 0);

  signal result_image                                         : out_memory;

  constant c_filename_image1                                  : string := "SOURCE.csv";
  constant c_filename_out                                     : string := "TARGET.ppm";
  file fptr                                                   : text;

  signal test_string                                          : string(1 to 1);

  signal r_image1_load_col                                    : integer := 0;
  signal r_image1_load_row                                    : integer := 0;

  type t_camera_faker_states is (CLOSE_FILE, PREPARE, LOAD_ROW, NEXT_ROW, FINISHED);

  signal w_camera_faker_next_state                            : t_camera_faker_states;
  signal r_camera_faker_current_state                         : t_camera_faker_states := CLOSE_FILE;

  -- Current column and row of the result image
  signal r_current_out_column                                 : integer := 0;
  signal r_current_out_row                                    : integer := 0;

  signal w_reset_raw2rgb                                      : std_logic;

  type t_process_states is (CLOSE_FILE, LOAD_DATA, WRITE_DATA, FINISHED);

  signal w_process_next_state                                 : t_process_states;
  signal r_process_current_state                              : t_process_states := CLOSE_FILE;

  signal r_current_write_column                               : integer := 0;
  signal r_current_write_row                                  : integer := 0;
  signal r_current_write_color                                : integer := 0;

begin

  DUT : RAW2RGB
    port map (
      I_CLOCK                      => clk_pixel_s,
      I_RESET_N                    => w_reset_raw2rgb,
      I_PIXEL_RAW                  => r_pixel,
      I_LVAL                       => r_lval,
      O_PIXEL_PROCESSED_FULL_WIDTH => pixel_out_s,
      O_PIXEL_PROCESSED_DOWNSIZED  => pixel_out_reduced_size_s,
      O_PIXEL_OUT_VALID            => pixel_out_valid_s
    );

  -- Schreibtest

  pixel_out_red_s   <= pixel_out_s(35 downto 24);
  pixel_out_green_s <= pixel_out_s(23 downto 12);
  pixel_out_blue_s  <= pixel_out_s(11 downto 0);

  pixel_out_red_reduced_s   <= pixel_out_reduced_size_s(23 downto 16);
  pixel_out_green_reduced_s <= pixel_out_reduced_size_s(15 downto 8);
  pixel_out_blue_reduced_s  <= pixel_out_reduced_size_s(7 downto 0);

  P_CLK : process is

  begin

    clk_pixel_s <= '1';
    wait for 10 ns;
    clk_pixel_s <= '0';
    wait for 10 ns;

  end process P_CLK;

  PROC_STATE_FF : process (w_reset_n, clk_tb_s) is
  begin

  end process PROC_STATE_FF;

  PROC_STATE_OUT : process (r_camera_faker_current_state, r_image1_load_col, r_image1_load_row, r_current_out_column, r_current_out_row, w_ready) is

    variable v_col_count_image1 : integer := 0;
    variable v_row_count_image1 : integer := 0;

    variable v_col_count_image2 : integer := 0;
    variable v_row_count_image2 : integer := 0;
    variable v_current_cycle    : integer := 1;

    variable v_current_disparity_column : integer := 0;

    variable v_fstatus  : file_open_status;
    variable v_line_out : line;

    file image1 : text open read_mode is c_filename_image1;

    variable v_current_image1_line : line;
    variable v_current_image2_line : line;

  begin

    case r_camera_faker_current_state is

      when CLOSE_FILE =>
        w_camera_faker_next_state <= PREPARE;

        w_write_enable  <= '0';
        w_reset_raw2rgb <= '0';
        lval_s          <= '0';

      when PREPARE =>

        w_camera_faker_next_state <= LOAD_ROW;

        w_write_enable  <= '0';
        w_reset_raw2rgb <= '1';
        lval_s          <= '0';

      when LOAD_ROW =>

        lval_s <= '1';

        if (r_image1_load_col = c_image_width - 1 and r_image1_load_row = c_image_height - 1) then
          w_camera_faker_next_state <= FINISHED;
        elsif (r_image1_load_col = c_image_width - 1 and r_image1_load_row < c_image_height - 1) then
          w_camera_faker_next_state <= NEXT_ROW;
        else
          w_camera_faker_next_state <= LOAD_ROW;
        end if;

        w_write_enable  <= '1';
        w_reset_raw2rgb <= '1';

      when NEXT_ROW =>
        lval_s <= '0';

        w_camera_faker_next_state <= LOAD_ROW;
        w_reset_raw2rgb           <= '1';

      when FINISHED =>
        w_write_enable  <= '0';
        w_reset_raw2rgb <= '1';
        lval_s          <= '0';

    end case;

  end process PROC_STATE_OUT;

  PROC_FILE_HANDLER_IN : process (w_reset_n, clk_pixel_s) is

    file image1 : text open read_mode is c_filename_image1;

    variable current_image1_line : line;
    variable current_image2_line : line;

  begin

    if (w_reset_n = '0') then
      r_pixel                      <= (others => '0');
      r_camera_faker_current_state <= CLOSE_FILE;
    elsif (rising_edge(clk_pixel_s)) then
      r_camera_faker_current_state <= w_camera_faker_next_state;
      
      case r_camera_faker_current_state is
        
        when CLOSE_FILE =>
        r_lval                       <= '0';
        
        when PREPARE =>
        
        readline(image1, current_image1_line);
        
        when LOAD_ROW =>
        get_integer(current_image1_line, r_pixel);
        r_lval                       <= '1';
        
        if (r_image1_load_col < c_image_width - 1) then
            r_image1_load_col <= r_image1_load_col + 1;
        else
            r_image1_load_col <= 0;
        end if;
        
        if (r_image1_load_col = c_image_width - 1) then
            if (r_image1_load_row < c_image_height - 1) then
                readline(image1, current_image1_line);
                r_image1_load_row <= r_image1_load_row + 1;
            else
                r_image1_load_row <= 0;
            end if;
        end if;
        
        when NEXT_ROW =>
        r_lval                       <= '0';
        
        when FINISHED =>
        r_lval                       <= '0';

      end case;

    end if;

  end process PROC_FILE_HANDLER_IN;

  PROC_PROCESS_VALID_PIXEL : process (w_reset_n, clk_pixel_s) is

    variable fstatus  : file_open_status;
    variable line_out : line;

  begin

    if (w_reset_n = '0') then
    elsif (rising_edge(clk_pixel_s)) then

      case r_process_current_state is

        when CLOSE_FILE =>
          file_close(fptr);
          file_open(fstatus, fptr, c_filename_out, write_mode);

          r_process_current_state <= LOAD_DATA;

          write(line_out, string'("P3"));
          writeline(fptr, line_out);
          write(line_out, string'("# Ausgangsbild"));
          writeline(fptr, line_out);
          write(line_out, string'("640 480"));
          writeline(fptr, line_out);
          write(line_out, string'("255"));
          writeline(fptr, line_out);

        when LOAD_DATA =>
          if (pixel_out_valid_s = '1') then
            result_image(r_current_out_row, r_current_out_column) <= pixel_out_reduced_size_s;

            if (r_current_out_column < c_result_image_width - 1) then
              r_current_out_column <= r_current_out_column + 1;
            else
              r_current_out_column <= 0;
            end if;

            if (r_current_out_column = c_result_image_width - 1) then
              if (r_current_out_row < c_result_image_height - 1) then
                r_current_out_row <= r_current_out_row + 1;
              else
                r_current_out_row <= 0;
              end if;
            end if;
          end if;

          if (r_current_out_column = c_result_image_width - 1 and r_current_out_row = c_result_image_height - 1) then
            r_process_current_state <= WRITE_DATA;
          end if;

        when WRITE_DATA =>
          if (r_current_write_color < 2) then
            r_current_write_color <= r_current_write_color + 1;
          else
            r_current_write_color <= 0;
          end if;

          if (r_current_write_color = 2) then
            if (r_current_write_column < c_result_image_width - 1) then
              r_current_write_column <= r_current_write_column + 1;
            else
              r_current_write_column <= 0;
            end if;
          end if;

          if (r_current_write_column = c_result_image_width - 1 and r_current_write_color = 2) then
            if (r_current_write_row < c_result_image_height - 1) then
              r_current_write_row <= r_current_write_row + 1;
            else
              r_current_write_row <= 0;
            end if;
          end if;

          if (r_current_write_color = 0) then
            write(line_out, to_integer(unsigned(result_image(r_current_write_row, r_current_write_column)(23 downto 16))));
          elsif (r_current_write_color = 1) then
            write(line_out, to_integer(unsigned(result_image(r_current_write_row, r_current_write_column)(15 downto 8))));
          else
            write(line_out, to_integer(unsigned(result_image(r_current_write_row, r_current_write_column)(7 downto 0))));
          end if;

          if (r_current_write_column = c_result_image_width - 1 and r_current_write_color = 2) then
            writeline(fptr, line_out);
          else
            write(line_out, string'(" "));
          end if;

          if (r_current_write_column = c_result_image_width - 1 and r_current_write_row = c_result_image_height - 1 and r_current_write_color = 2) then
            r_process_current_state <= FINISHED;
          end if;

        when FINISHED =>
          file_close(fptr);

      end case;

    end if;

  end process PROC_PROCESS_VALID_PIXEL;

end architecture ARCH;
