-- OSVVM-based robust testbench for the MMU
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library osvvm;
use osvvm.RandomPkg.all;
use osvvm.ScoreboardPkg.all;
use osvvm.CoveragePkg.all;

entity tb_mmu_osvvm is
end entity tb_mmu_osvvm;

architecture sim of tb_mmu_osvvm is
  -- DUT port signals
  signal LAB_tb       : std_logic_vector(31 downto 0) := (others => '0');
  signal RW_tb        : std_logic := '1';
  signal CS_tb        : std_logic := '1';
  signal CLK_tb       : std_logic := '0';
  signal DB_tb        : std_logic_vector(31 downto 0) := (others => 'Z');
  signal PAB_tb       : std_logic_vector(41 downto 0);
  signal SegFault_tb  : std_logic;
  signal ProtFault_tb : std_logic;

  -- OSVVM utilities
  constant SEED1 : positive := 1;
  shared variable RandGen : RandomPType;
  shared variable SB      : ScoreboardPType;
  shared variable COV     : CoveragePType;

  -- Reference model record
  type seg_rec is record
    valid      : boolean;
    phys_base  : unsigned(31 downto 0);
    log_base   : unsigned(31 downto 0);
    mask       : unsigned(31 downto 0);
    enabled    : boolean;
    wp         : boolean;
  end record;

  type seg_arr_rec is array(0 to 3) of seg_rec;
  shared variable seg_table : seg_arr_rec;

  -- Predictor function: given seg_table and inputs, compute expected outputs
  procedure predict(
    signal addr      : in  std_logic_vector(31 downto 0);
           table     : in  seg_arr_rec;
    signal exp_PAB   : out std_logic_vector(41 downto 0);
           exp_SF    : out std_logic;
           exp_PF    : out std_logic) is
    variable la       : unsigned(31 downto 0) := unsigned(addr);
    variable matched : integer := -1;
    variable tmp      : unsigned(41 downto 0);
  begin
    -- find matching segment
    for i in 0 to 3 loop
      if table(i).valid and ((la and table(i).mask) = (table(i).log_base and table(i).mask)) then
        matched := i;
        exit;
      end if;
    end loop;
    exp_PF  := '1';
    exp_SF  := '1';
    tmp      := (others => '0');
    if matched = -1 then  -- no match
      exp_SF := '0';
    else
      -- check enable
      if not table(matched).enabled then
        exp_SF := '0';
      else
        -- compute PAB: phys_base & offset
        tmp(41 downto 32) := table(matched).phys_base(31 downto 22);
        tmp(31 downto 10) := (table(matched).phys_base(21 downto 0) and not table(matched).mask(21 downto 0))
                             or (table(matched).log_base(21 downto 0) and table(matched).mask(21 downto 0));
        tmp(9 downto 0)   := la(9 downto 0);
        exp_PAB := std_logic_vector(tmp);
        -- check write protection if write
        if RW_tb = '0' and table(matched).wp then
          exp_PF := '0';
        end if;
      end if;
    end if;
  end procedure;

begin
  -- DUT instantiation
  UUT: entity work.MMU(behavioral)
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

  -- Clock generation
  clk_proc: process
  begin
    wait for 5 ns;
    CLK_tb <= not CLK_tb;
  end process;

  -- Initialize OSVVM random, scoreboard, coverage
  init_proc: process
  begin
    RandGen.InitSeed(SEED1);
    SB.Init;
    -- coverage on fault conditions
    COV.AddBins("normal",    ((SegFault_tb='1') and (ProtFault_tb='1')));
    COV.AddBins("sfault",    (SegFault_tb='0'));
    COV.AddBins("pfault",    (ProtFault_tb='0'));
    wait;
  end process;

  -- Driver and predictor
  stim_proc: process
    variable exp_PAB   : std_logic_vector(41 downto 0);
    variable exp_SF    : std_logic;
    variable exp_PF    : std_logic;
    variable seg_idx   : integer;
    variable rand_addr : unsigned(31 downto 0);
  begin
    -- wait for reset
    wait for 20 ns;

    -- randomize segment table entries
    for i in 0 to 3 loop
      -- randomly decide if valid
      seg_table(i).valid    := RandGen.RandBoolean(0.8);
      seg_table(i).phys_base:= RandGen.RandSlv(32)(unsigned'("00000000000000000000000000000000"));
      seg_table(i).log_base := RandGen.RandSlv(32)(unsigned'("00000000000000000000000000000000"));
      seg_table(i).mask     := to_unsigned(16#FFFFFC00#, 32);
      seg_table(i).enabled  := RandGen.RandBoolean(0.9);
      seg_table(i).wp       := RandGen.RandBoolean(0.5);
      -- write registers into DUT
      CS_tb <= '0'; RW_tb <= '0';
      for off in 0 to 3 loop
        LAB_tb(3 downto 0) <= std_logic_vector(to_unsigned(i*4+off, 4));
        case off is
          when 0 => DB_tb <= std_logic_vector(seg_table(i).phys_base);
          when 1 => DB_tb <= std_logic_vector(seg_table(i).log_base);
          when 2 => DB_tb <= std_logic_vector(seg_table(i).mask);
          when 3 =>  -- status bits
            DB_tb <= (others => '0');
            DB_tb(27) <= '1' when seg_table(i).enabled else '0';
            DB_tb(29) <= '1' when seg_table(i).wp      else '0';
        end case;
        wait until rising_edge(CLK_tb);
      end loop;
      DB_tb <= (others => 'Z');
    end loop;

    -- random addresses and check
    CS_tb <= '1'; RW_tb <= '1';
    for t in 1 to 1000 loop  -- 1000 random tests
      -- randomize LAB
      rand_addr := RandGen.RandSlv(32)(to_unsigned(0,32));
      LAB_tb    <= std_logic_vector(rand_addr);
      -- randomly choose read or write
      RW_tb     <= '0' when RandGen.RandBoolean(0.3) else '1';
      wait for 10 ns;
      -- predict
      predict(LAB_tb, seg_table, exp_PAB, exp_SF, exp_PF);
      -- score
      SB.WriteLine("Addr=" & to_hstring(LAB_tb) & " RW=" & RW_tb & " got PAB=" & to_hstring(PAB_tb));
      SB.CompareString("SegFault", SegFault_tb, exp_SF);
      SB.CompareStdLogicVector("PAB", PAB_tb, exp_PAB);
      SB.CompareString("ProtFault", ProtFault_tb, exp_PF);
      -- coverage
      COV.CoverPoint;
    end loop;

    -- report
    WriteReport("MMU Scoreboard Results", SB);
    -- SB.Report;
    ReportCoverage("MMU Coverage Results", COV);
    -- COV.Report;

    wait;
  end process;

end architecture sim;
