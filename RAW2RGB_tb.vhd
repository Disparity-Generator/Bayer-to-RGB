library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;
  use std.textio.all;
  use ieee.std_logic_textio.all;

entity tb_raw2rgb is -- keine Schnittstellen
end entity tb_raw2rgb;

architecture arch of tb_raw2rgb is

  signal clk_pixel_s : std_logic;
  signal reset_n_s   : std_logic;
  signal pixel_in_s  : std_logic_vector(11 downto 0);
  signal lval_s      : std_logic;

  signal pixel_out_s       : std_logic_vector(35 downto 0);
  signal pixel_out_reduced_size_s : std_logic_vector(23 downto 0);
  signal pixel_out_valid_s : std_logic;

  signal pixel_out_red_s   : std_logic_vector(11 downto 0);
  signal pixel_out_green_s : std_logic_vector(11 downto 0);
  signal pixel_out_blue_s  : std_logic_vector(11 downto 0);

  signal pixel_out_red_reduced_s   : std_logic_vector(7 downto 0);
  signal pixel_out_green_reduced_s : std_logic_vector(7 downto 0);
  signal pixel_out_blue_reduced_s  : std_logic_vector(7 downto 0);

  component raw2rgb is
    generic (
      -- The fifo width has to be altered manually!!
      g_input_color_width  : natural := 12;
      g_result_color_width : natural := 8
    );
    port (
      i_clock : in    std_logic;
      i_reset_n     : in    std_logic;
      i_pixel_raw   : in    std_logic_vector(g_input_color_width - 1 downto 0);
      i_lval        : in    std_logic;

      o_pixel_processed_full_width : out   std_logic_vector((3 * g_input_color_width) - 1 downto 0);
      o_pixel_processed_downsized  : out   std_logic_vector((3 * g_result_color_width) - 1 downto 0);
      o_pixel_out_valid            : out   std_logic
    );
  end component raw2rgb;

begin

  dut : component raw2rgb
    port map (
      i_clock                => clk_pixel_s,
      i_reset_n                    => reset_n_s,
      i_pixel_raw                  => pixel_in_s,
      i_lval                       => lval_s,
      o_pixel_processed_full_width => pixel_out_s,
      o_pixel_processed_downsized  => pixel_out_reduced_size_s,
      o_pixel_out_valid            => pixel_out_valid_s
    );

  -- Schreibtest

  pixel_out_red_s   <= pixel_out_s(35 downto 24);
  pixel_out_green_s <= pixel_out_s(23 downto 12);
  pixel_out_blue_s  <= pixel_out_s(11 downto 0);

  pixel_out_red_reduced_s   <= pixel_out_reduced_size_s(23 downto 16);
  pixel_out_green_reduced_s <= pixel_out_reduced_size_s(15 downto 8);
  pixel_out_blue_reduced_s  <= pixel_out_reduced_size_s(7 downto 0);

  p_clk : process is

  begin

    clk_pixel_s <= '1';
    wait for 50 ns;
    clk_pixel_s <= '0';
    wait for 50 ns;

  end process p_clk;

  tests_p : process is
  begin

    reset_n_s <= '1';


    wait until falling_edge(clk_pixel_s);
    wait until falling_edge(clk_pixel_s);

    lval_s    <= '1';

    pixel_in_s <= "011110110111";         -- 1. Pixel 1. Zeile (Grün 1) 1975
    wait until falling_edge(clk_pixel_s);

    pixel_in_s <= "110000110011";         -- 1. Pixel 1. Zeile (Rot) 3123
    wait until falling_edge(clk_pixel_s);

    pixel_in_s <= "111111111111";         -- 2. Pixel 1. Zeile (Grün 1) 4095
    wait until falling_edge(clk_pixel_s);

    pixel_in_s <= "111110011111";         -- 2. Pixel 1. Zeile (Rot) 3999
    wait until falling_edge(clk_pixel_s);

    lval_s <= '0';                        -- Nächste Zeile

    wait until falling_edge(clk_pixel_s);
    lval_s <= '1';

    pixel_in_s <= "010011010010";         -- 1. Pixel 2. Zeile (Blau) 1234
    wait until falling_edge(clk_pixel_s);

    pixel_in_s <= "000101111011";         -- 1. Pixel 2. Zeile (Grün 2) 379

    wait until falling_edge(clk_pixel_s);
    pixel_in_s <= "101001010101";         -- 2. Pixel 2. Zeile (Blau) 2645

    wait until falling_edge(clk_pixel_s);
    pixel_in_s <= "111111111111";         -- 2. Pixel 2. Zeile (Grün 2) 4095

    wait until falling_edge(clk_pixel_s);
    lval_s <= '0';

    -- Mittelwert vom ersten Grün: 1177 - 0100 1001 1001
    -- Mittelwert vom zweiten Grün: 377 - 0001 0111 1001

    -- Pixel 1 komplett: 1100 0011 0011 0100 1001 1001 0100 1101 0010
    -- 3123 1177 1234

    -- Pixel 2 komplett: 1111 1010 0000 0001 0111 1001 1010 0101 0101
    -- 3099 4095 2645

    wait;

  end process tests_p;

end architecture arch;
