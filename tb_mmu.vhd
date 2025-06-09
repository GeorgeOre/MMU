----------------------------------------------------------------------------
--
--  Memory Managment Unit Testbench
--
--  This file contains the testbench for the memory managment unit (MMU)
--  to be implementated as described in the EE188 HW4 specifications. The
--  This testbench verifies all four segments in the MMU by:
--      - Writing and reading all segment registers
--      - Testing all enable (E) and write-protect (WP) permutations
--      - Performs address-translation checks
--      - Checking SegFault and ProtFault as checkpoints
--  Then at the end there is a final out-of-range segfault test for completion.
--
--  Revision History:
--     25 May 2025      George Ore      Initial revision.
--     7 June 2025      George Ore      Second revision.
--     8 June 2025      George Ore      Final revision.
--
----------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_mmu is
end entity;

architecture tb of tb_mmu is
  component MMU
    port(
      LAB       : in  std_logic_vector(31 downto 0);
      RW        : in  std_logic;
      CS        : in  std_logic;
      CLK       : in  std_logic;
      DB        : inout std_logic_vector(31 downto 0);
      PAB       : out std_logic_vector(41 downto 0);
      SegFault  : out std_logic;
      ProtFault : out std_logic
    );
  end component;

  -- signals
  signal CLK_tb      : std_logic := '0';
  signal CS_tb       : std_logic := '0';
  signal RW_tb       : std_logic := '1';
  signal LAB_tb      : std_logic_vector(31 downto 0) := (others => '0');
  signal DB_tb       : std_logic_vector(31 downto 0) := (others => 'Z');
  signal PAB_tb      : std_logic_vector(41 downto 0);
  signal SegFault_tb : std_logic;
  signal ProtFault_tb: std_logic;

  -- helper constants
  constant MASK_1KB  : std_logic_vector(31 downto 0) := x"FFFFFC00";

begin
  -- instantiate unit under test (UUT)
  UUT: MMU
    port map(
      LAB       => LAB_tb,
      RW        => RW_tb,
      CS        => CS_tb,
      CLK       => CLK_tb,
      DB        => DB_tb,
      PAB       => PAB_tb,
      SegFault  => SegFault_tb,
      ProtFault => ProtFault_tb
    );

  -- clock: 10 ns period
  clk_gen: process
  begin
    while true loop
      CLK_tb <= '0'; wait for 5 ns;
      CLK_tb <= '1'; wait for 5 ns;
    end loop;
  end process;

  stim: process
    -- local variables
    variable e_bit    : std_logic;
    variable wp_bit   : std_logic;
    variable base_phys: std_logic_vector(31 downto 0);
    variable base_log : std_logic_vector(31 downto 0);
    variable addr     : std_logic_vector(31 downto 0);
  begin
    -- allow reset
    wait for 20 ns;

    -- trigger segfault when no info in any segment
    CS_tb <= '1'; RW_tb <= '1'; LAB_tb <= x"00001000";
    wait for 10 ns;
    assert SegFault_tb = '0' report "FAIL: SegFault not asserted on empty table" severity error;

    -- Test each of the 4 segments individually
    for seg in 0 to 3 loop
      -- set distinct base addresses
      base_phys := std_logic_vector(to_unsigned( (seg+1)*16#100#, 32));
      base_log  := std_logic_vector(to_unsigned( seg*16#400#, 32));

      -- Test all E and WP permutations
      for e_val in 0 to 1 loop
        for wp_val in 0 to 1 loop
          -- write all 4 registers for this segment
          CS_tb <= '0'; RW_tb <= '0';
          -- PAB base (offset 0)
          LAB_tb(3 downto 0) <= std_logic_vector(to_unsigned(seg*4 + 0, 4));
          DB_tb    <= base_phys;
          wait for 10 ns;
          -- LAB base (offset 1)
          LAB_tb(3 downto 0) <= std_logic_vector(to_unsigned(seg*4 + 1, 4));
          DB_tb    <= base_log;
          wait for 10 ns;
          -- mask (offset 2)
          LAB_tb(3 downto 0) <= std_logic_vector(to_unsigned(seg*4 + 2, 4));
          DB_tb    <= MASK_1KB;
          wait for 10 ns;
          -- status (offset 3)
          LAB_tb(3 downto 0) <= std_logic_vector(to_unsigned(seg*4 + 3, 4));
          DB_tb    <= (others => '0');
          e_bit    := std_logic'VAL(e_val);
          wp_bit   := std_logic'VAL(wp_val);
          DB_tb(27) <= e_bit;
          DB_tb(29) <= wp_bit;
          wait for 10 ns;
          DB_tb <= (others => 'Z');

          -- Read all registers to verify that they were set correctly
          CS_tb <= '0'; RW_tb <= '1';
          for i in 0 to 3 loop
            LAB_tb(3 downto 0) <= std_logic_vector(to_unsigned(seg*4 + i,4));
            wait for 10 ns;
            -- Test expected values
            case i is
              when 0 =>
                assert DB_tb = base_phys  report "Read-back PAB base mismatch: seg" & integer'image(seg) severity error;
              when 1 =>
                assert DB_tb = base_log   report "Read-back LAB base mismatch: seg" & integer'image(seg) severity error;
              when 2 =>
                assert DB_tb = MASK_1KB   report "Read-back mask mismatch: seg" & integer'image(seg) severity error;
              when 3 =>
                assert DB_tb(27) = e_bit  report "Read-back E bit mismatch: seg" & integer'image(seg) severity error;
                assert DB_tb(29) = wp_bit report "Read-back WP bit mismatch: seg" & integer'image(seg) severity error;
            end case;
          end loop;

          -- Now test address translation (read)
          CS_tb <= '1'; RW_tb <= '1';
          -- Read into a random address with offset 0x3
          addr := base_log;
          addr(9 downto 0) := "0000000011";
          LAB_tb <= addr; wait for 10 ns;

          -- Handle enable bit error checking
          if e_bit = '0' then
            assert SegFault_tb = '0' report "Disabled seg should fault seg: seg" & integer'image(seg) severity error;
          else
            assert SegFault_tb = '1' report "Enabled seg unexpectedly faulted: seg"   & integer'image(seg) severity error;
            
            -- Upper PAB translation check
            assert PAB_tb(41 downto 32) = base_phys(31 downto 22) report "Enabled seg did not map upper physical base correctly: seg" & integer'image(seg) severity error;
            
            -- Middle PAB translation check
            assert PAB_tb(31 downto 10) = ((base_phys(21 downto 0) and not MASK_1KB(21 downto 0)) or (base_log(21 downto 0) and MASK_1KB(21 downto 0))) report "Enabled seg did not map middle physical base correctly: seg" & integer'image(seg) severity error;

            -- Lower PAB translation check
            assert PAB_tb(9 downto 0)   = "0000000011" report "Enabled seg did not map offset correctly: seg" & integer'image(seg) severity error;
            
            -- Test write protection
            CS_tb <= '1'; RW_tb <= '0'; LAB_tb <= addr; wait for 10 ns;
            if wp_bit = '1' then
              assert ProtFault_tb = '0' report "WP seg should ProtFault"  & integer'image(seg) severity error;
            else
              assert ProtFault_tb = '1' report "Non-WP seg should allow write" severity error;
            end if;
          end if;

        end loop;
      end loop;
    end loop;

    -- Do a final segfault test with an out-of-range address
    CS_tb <= '1'; RW_tb <= '1'; LAB_tb <= x"FFFFF000"; wait for 10 ns;
    assert SegFault_tb = '0' report "FAIL: Out-of-range address did not fault" severity error;

    report "All tests passed!";
    wait;
  end process;
end architecture tb;
