----------------------------------------------------------------------------
--
--  Memory Managment Unit
--
--  This file contains the memory managment unit (MMU) implementation as
--  described in the EE188 HW4 specifications. The MMU divides memory into
--  segments, each of which is a power of 2 in size (2^10 or 1024 words).
--  Each segment is mapped to a block of physical addresses that is also a
--  power of 2 in size. The logical address space has 32 bits of address
--  while the physical address space has 42 bits of address.
--  
--  Much of the memory management work will be done by the CPU/OS. Thus,
--  the MMU doesn't need to access the external segment table. The CPU/OS
--  will load the MMU registers (cache) with values from that table as
--  needed.
--  
--  The 32-bit logical address bus is given by the signal LAB of type
--  std_logic_vector(31 downto 0).
--  
--  The address interface also has a read/write signal (high for read,
--  low for write) called RW that is of type std_logic.
--  
--  The 42-bit physical address bus is given by the signal PAB of type
--  std_logic_vector(41 downto 0).
--  
--  There is also a system clock signal CLK that is of type std_logic.
--  
--  The MMU contains four (4) sets of segment registers describing the
--  four segments currently cached in the MMU. These segment registers can
--  be read or written by the CPU using the logical address bus LAB, the
--  data bus DB of type std_logic_vector(31 downto 0), plus an active-low
--  chip select signal CS, of type std_logic.
--  
--  Each set of registers consists of a 22-bit logical address mask which
--  defines the segment size, a 22-bit starting logical address which when
--  combined with the mask gives the segment number, a 32-bit starting
--  physical address, a 16-bit segment index that gives the entry number in
--  the segment table, and five (5) bits of status. The status bits and
--  segment index are combined into a single 32-bit register with the status
--  bits in the upper five (5) bits and the segment index in the lower 16-bits.
--  Thus there are four (4) registers for each segment and the MMU occupies
--  16 words of memory.
--  
--  The starting physical address is at offset 0, the starting logical address
--  is at offset 1, the logical address mask is at offset 2, and the index/status
--  register is at offset 3 within each block of four (4) addresses for the
--  segment registers.
--  
--  The five (5) status bits, all of which are readable and writable by the CPU,
--  are defined in the following table. Note that only the U, D, and F bits are
--  updated by the MMU. The E and WP bits are never changed by the MMU.
--  
--  Bit Name    Bit Number  Description
--    U 31  the segment has been used (read or written)
--    D 30  the segment is dirty (has been written to)
--    WP    29  the segment is write protected (cannot be written to)
--    F 28  the segment generated a protection fault
--    E 27  the segment is enabled
--  
--  There are two fault signals output by the MMU, both of type std_logic. The
--  signal SegFault is active low and indicates there is no matching segment
--  (logical address) defined in the MMU. The second signal is ProtFault, also
--  active low, and indicates there was an attempt to write to a write
--  protected segment.
--
--  When there is a fault or error, DB is set to high impedance and PAB is
--  set to 0x3FFDEADBEEF.
--
--  Revision History:
--     25 May 2025      George Ore      Initial revision.
--     7 June 2025      George Ore      Final revision.
--
----------------------------------------------------------------------------


library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;


entity MMU is


    port (
     -- MMU Input Signals
        LAB     : in    std_logic_vector(31 downto 0);  -- logical address bus
        RW      : in    std_logic;                      -- read/!write
        CS      : in    std_logic;                      -- chip select
        CLK     : in    std_logic;                      -- system clock
     -- MMU In/Out Signals
        DB      : inout std_logic_vector(31 downto 0);  -- data bus
     -- MMU Output Signals
        PAB     : out   std_logic_vector(41 downto 0);  -- physical address bus
        SegFault    : out   std_logic;                  -- segmentation fault signal
        ProtFault   : out   std_logic                   -- write protection fault signal
    );


end MMU;


architecture behavioral of MMU is


    -- Constants
    constant W_SIZE     :   integer := 32;-- word size in bits
    constant SEG_CNT    :   integer := 4; -- number of segments


    constant SEG_PAB    :   integer := 0; -- index of physical address base segment word
    constant SEG_LAB    :   integer := 1; -- index of logical address base segment word
    constant SEG_MASK   :   integer := 2; -- index of logical address mask segment word
    constant SEG_STAT_IDX : integer := 3; -- index of segment index/status segment word
    constant SEG_SIZE_W :   integer := 4; -- segment size in words (4 words = 16 bytes)


    constant U_INDEX    :   integer := 31; -- index of U bit in status/index register
    constant D_INDEX    :   integer := 30; -- index of D bit in status/index register
    constant WP_INDEX   :   integer := 29; -- index of WP bit in status/index register
    constant F_INDEX    :   integer := 28; -- index of F bit in status/index register
    constant E_INDEX    :   integer := 27; -- index of E bit in status/index register


    -- Declare segment type
    type segment_t is array(0 to SEG_SIZE_W-1) of std_logic_vector(W_SIZE-1 downto 0);


    -- Declare segment array type
    type seg_arr_t is array(0 to SEG_CNT-1) of segment_t;


    -- Instantiate segment array
    signal s_array : seg_arr_t;

    -- Segment register data bus signal (used when reading into segment registers)
    signal db_out   : std_logic_vector(W_SIZE-1 downto 0);

    -- Segment match detection mask
    signal match_mask : std_logic_vector(SEG_CNT-1 downto 0) := (others => '0');

    -- Physical address bus concatenation signals
    signal upper_PAB : std_logic_vector(31 downto 22);  -- upper 10 bits of PAB
    signal middle_PAB : std_logic_vector(21 downto 0);  -- middle 22 bits of PAB
    signal lower_PAB : std_logic_vector(9 downto 0);   -- lower 10 bits of PAB

begin

  -- LAB Match Signal Generation
  MatchMaskGen: for i in 0 to SEG_CNT-1 generate
    match_mask(i) <= '1' when (s_array(i)(SEG_LAB)(31 downto 10) and s_array(i)(SEG_MASK)(31 downto 10)) = (LAB(31 downto 10) and s_array(i)(SEG_MASK)(31 downto 10)) else '0';
  end generate MatchMaskGen;


  -- Segment Array Register Process
  seg_array : process(CLK)
    variable word_off     : integer;
    variable seg_i        : integer;
    variable matched_seg  : integer := -1;
  begin
    -- Registers in segment array should only be accessed on rising edge of clock
    if rising_edge(CLK) then

      -- Initialize default fault output values
      SegFault  <= '1';  -- No seg fault
      ProtFault <= '1';  -- No protection fault

      -- CS low indicated direct segment register access
      if CS = '0' then
        
        -- Calculate which segment is being accessed
        -- LAB[1:0] contains the segment word offset
        word_off := to_integer(unsigned(LAB(1 downto 0)));
        -- LAB[3:2] selects one of 4 segments
        seg_i    := to_integer(unsigned(LAB(3 downto 2)));

        -- Handle segment register read/write
        if RW = '0' then  -- write
          s_array(seg_i)(word_off)   <= DB;
        else              -- read
          db_out <= s_array(seg_i)(word_off);
        end if;


      else
      -- CS high indicates normal address translation mode
        
        -- Set db_out to high impedance to prevent driving it
        db_out <= (others => 'Z');

        -- Set matched segment index variable based on match_mask
        matched_seg := 0 when match_mask = "0001" else
                       1 when match_mask = "0010" else
                       2 when match_mask = "0100" else
                       3 when match_mask = "1000" else
                      -1;  -- invalid or no match

        -- Calculate PAB depending on segment match
        if matched_seg /= -1 then
          -- Single segment match found

          -- Make sure that the segment is enabled
          if s_array(matched_seg)(SEG_STAT_IDX)(E_INDEX) = '0' then
            SegFault <= '0';  -- segment not enabled, set fault

          else
            -- Segment is enabled, proceed with translation
            upper_PAB <= s_array(matched_seg)(SEG_PAB)(31 downto 22);  -- upper 10 PAB base bits
            middle_PAB <= (s_array(matched_seg)(SEG_PAB)(21 downto 0) and not s_array(matched_seg)(SEG_MASK)(21 downto 0))
                        or (s_array(matched_seg)(SEG_LAB)(21 downto 0) and s_array(matched_seg)(SEG_MASK)(21 downto 0));
            lower_PAB <= LAB(9 downto 0);  -- LAB 10 bit offset

            -- Handle status bits

            -- Used (U) status bit indicates usage (R or W)
            s_array(matched_seg)(SEG_STAT_IDX)(U_INDEX) <= '1';

            -- Dirty (D) status bit indicates write history
            if RW = '0' then
              s_array(matched_seg)(SEG_STAT_IDX)(D_INDEX) <= '1';

            -- Write Protection (WP) status bit handling

              -- Generate a protection fault if WP enabled
              if s_array(matched_seg)(SEG_STAT_IDX)(WP_INDEX) = '1' then
                ProtFault <= '0';

                -- Set status bit if not already set
                s_array(matched_seg)(SEG_STAT_IDX)(F_INDEX) <= '1';
              end if;
              
            end if; -- RW = '0' (write)

          end if; -- E bit check

        -- Else you have invalid or no segment match
        else
          SegFault <= '0';  -- Set segmentation fault

        end if; -- matched_seg check

      end if; -- CS = '0' (segment register access) or '1' (address translation)

    end if; -- rising_edge(CLK)

  end process; -- seg_array

  -- Drive DB during segment register reads
  DB  <= db_out when (CS = '0' and RW = '1') 
        else (others => 'Z');

  -- Construct PAB from its parts in translation mode with no segmentation fault
  PAB <= upper_PAB & middle_PAB & lower_PAB when (CS = '1' and SegFault = '1') 
        else "111111111111011110101011011011111011101111"; -- Default PAB is 0x3FFDEADBEEF

end architecture behavioral;


