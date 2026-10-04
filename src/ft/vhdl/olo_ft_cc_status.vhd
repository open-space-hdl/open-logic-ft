---------------------------------------------------------------------------------------------------
-- Copyright (c) 2026 by Julian Schneider
-- Authors: Julian Schneider
---------------------------------------------------------------------------------------------------

---------------------------------------------------------------------------------------------------
-- Description
---------------------------------------------------------------------------------------------------
-- TMR-hardened clock crossing for slowly changing status or configuration information. It is the
-- fault-tolerant counterpart of olo_base_cc_status with the same interface.
--
-- Documentation:
-- https://github.com/open-logic/open-logic/blob/main/doc/ft/olo_ft_cc_status.md
--
-- Note: The link points to the documentation of the latest release. If you
--       use an older version, the documentation might not match the code.

---------------------------------------------------------------------------------------------------
-- Libraries
---------------------------------------------------------------------------------------------------
library ieee;
    use ieee.std_logic_1164.all;
    use ieee.numeric_std.all;

library work;
    use work.olo_base_pkg_attribute.all;
    use work.olo_ft_pkg_attribute.all;

---------------------------------------------------------------------------------------------------
-- Entity
---------------------------------------------------------------------------------------------------
entity olo_ft_cc_status is
    generic (
        Width_g      : positive;
        SyncStages_g : positive range 2 to 4 := 2
    );
    port (
        In_Clk      : in    std_logic;
        In_RstIn    : in    std_logic := '0';
        In_RstOut   : out   std_logic;
        In_Data     : in    std_logic_vector(Width_g - 1 downto 0);
        Out_Clk     : in    std_logic;
        Out_RstIn   : in    std_logic := '0';
        Out_RstOut  : out   std_logic;
        Out_Data    : out   std_logic_vector(Width_g - 1 downto 0)
    );
end entity;

---------------------------------------------------------------------------------------------------
-- Architecture
---------------------------------------------------------------------------------------------------
architecture rtl of olo_ft_cc_status is

    -----------------------------------------------------------------------------------------------
    -- Signals
    -----------------------------------------------------------------------------------------------
    -- Input Domain Signals
    signal RstInI      : std_logic;
    signal Started     : std_logic_vector(0 to 2) := (others => '0'); -- TMR copies (0 = A, 1 = B, 2 = C)
    signal VldIn       : std_logic_vector(0 to 2) := (others => '0'); -- TMR copies (0 = A, 1 = B, 2 = C)
    signal StartedVote : std_logic;
    signal VldInVote   : std_logic;
    signal VldFb       : std_logic;

    -- Output Domain Signals
    signal RstOutI : std_logic;
    signal VldOut  : std_logic;

    -----------------------------------------------------------------------------------------------
    -- Architecture-level attribute: disable vendor-provided TMR insertion.
    -- Manual TMR is already in place below.
    -----------------------------------------------------------------------------------------------
    attribute syn_radhardlevel of rtl : architecture is SynRadhardlevel_None_c;

    -----------------------------------------------------------------------------------------------
    -- Synthesis attributes - preserve registers (prevent merging of TMR copies)
    -----------------------------------------------------------------------------------------------
    attribute dont_touch of Started : signal is DontTouch_SuppressChanges_c;
    attribute dont_touch of VldIn   : signal is DontTouch_SuppressChanges_c;

    attribute dont_merge of Started : signal is DontMerge_SuppressChanges_c;
    attribute dont_merge of VldIn   : signal is DontMerge_SuppressChanges_c;

    attribute preserve of Started : signal is Preserve_SuppressChanges_c;
    attribute preserve of VldIn   : signal is Preserve_SuppressChanges_c;

    attribute syn_preserve of Started : signal is SynPreserve_SuppressChanges_c;
    attribute syn_preserve of VldIn   : signal is SynPreserve_SuppressChanges_c;

    attribute syn_keep of Started : signal is SynKeep_SuppressChanges_c;
    attribute syn_keep of VldIn   : signal is SynKeep_SuppressChanges_c;

begin

    -----------------------------------------------------------------------------------------------
    -- Valid pulse generation
    -----------------------------------------------------------------------------------------------
    -- Majority voters: (A*B) + (B*C) + (A*C)
    StartedVote <= (Started(0) and Started(1)) or
                   (Started(1) and Started(2)) or
                   (Started(0) and Started(2));
    VldInVote   <= (VldIn(0) and VldIn(1)) or
                   (VldIn(1) and VldIn(2)) or
                   (VldIn(0) and VldIn(2));

    p_vldgen : process (In_Clk) is
    begin
        if rising_edge(In_Clk) then
            -- Send valid after it is received back. The first valid pulse after reset is
            -- generated while Started is still low.
            VldIn   <= (others => VldFb or not StartedVote);
            Started <= (others => '1');

            -- Reset
            if RstInI = '1' then
                Started <= (others => '0');
                VldIn   <= (others => '0');
            end if;
        end if;
    end process;

    -----------------------------------------------------------------------------------------------
    -- Simple CC (path in->out)
    -----------------------------------------------------------------------------------------------
    i_scc : entity work.olo_ft_cc_simple
        generic map (
            Width_g      => Width_g,
            SyncStages_g => SyncStages_g
        )
        port map (
            In_Clk      => In_Clk,
            In_RstIn    => In_RstIn,
            In_RstOut   => RstInI,
            In_Data     => In_Data,
            In_Valid    => VldInVote,
            Out_Clk     => Out_Clk,
            Out_RstIn   => Out_RstIn,
            Out_RstOut  => RstOutI,
            Out_Data    => Out_Data,
            Out_Valid   => VldOut
        );

    In_RstOut  <= RstInI;
    Out_RstOut <= RstOutI;

    -----------------------------------------------------------------------------------------------
    -- Transfer valid back (path out->in)
    -----------------------------------------------------------------------------------------------
    i_bcc : entity work.olo_ft_private_cc_toggle
        generic map (
            SyncStages_g => SyncStages_g
        )
        port map (
            In_Clk    => Out_Clk,
            In_Rst    => RstOutI,
            In_Pulse  => VldOut,
            Out_Clk   => In_Clk,
            Out_Rst   => RstInI,
            Out_Pulse => VldFb
        );

end architecture;
