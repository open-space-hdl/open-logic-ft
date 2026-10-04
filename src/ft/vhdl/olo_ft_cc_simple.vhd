---------------------------------------------------------------------------------------------------
-- Copyright (c) 2026 by Julian Schneider
-- Authors: Julian Schneider
---------------------------------------------------------------------------------------------------

---------------------------------------------------------------------------------------------------
-- Description
---------------------------------------------------------------------------------------------------
-- TMR-hardened clock crossing for single data samples marked by a valid signal. It is the
-- fault-tolerant counterpart of olo_base_cc_simple with the same interface.
--
-- Documentation:
-- https://github.com/open-logic/open-logic/blob/main/doc/ft/olo_ft_cc_simple.md
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
entity olo_ft_cc_simple is
    generic (
        Width_g      : positive              := 1;
        SyncStages_g : positive range 2 to 4 := 2
    );
    port (
        In_Clk      : in    std_logic;
        In_RstIn    : in    std_logic := '0';
        In_RstOut   : out   std_logic;
        In_Data     : in    std_logic_vector(Width_g - 1 downto 0);
        In_Valid    : in    std_logic;
        Out_Clk     : in    std_logic;
        Out_RstIn   : in    std_logic := '0';
        Out_RstOut  : out   std_logic;
        Out_Data    : out   std_logic_vector(Width_g - 1 downto 0);
        Out_Valid   : out   std_logic
    );
end entity;

---------------------------------------------------------------------------------------------------
-- Architecture
---------------------------------------------------------------------------------------------------
architecture struct of olo_ft_cc_simple is

    -----------------------------------------------------------------------------------------------
    -- Signals
    -----------------------------------------------------------------------------------------------
    -- Input Domain signals
    signal RstInI          : std_logic;
    signal DataLatchInA    : std_logic_vector(Width_g - 1 downto 0);
    signal DataLatchInB    : std_logic_vector(Width_g - 1 downto 0);
    signal DataLatchInC    : std_logic_vector(Width_g - 1 downto 0);
    signal DataLatchInVote : std_logic_vector(Width_g - 1 downto 0);

    -- Output Domain signals
    signal RstOutI       : std_logic;
    signal VldOutI       : std_logic;
    signal Out_Data_SigA : std_logic_vector(Width_g - 1 downto 0);
    signal Out_Data_SigB : std_logic_vector(Width_g - 1 downto 0);
    signal Out_Data_SigC : std_logic_vector(Width_g - 1 downto 0);
    signal OutDataVote   : std_logic_vector(Width_g - 1 downto 0);
    signal OutValid      : std_logic_vector(0 to 2) := (others => '0'); -- TMR copies (0 = A, 1 = B, 2 = C)

    -----------------------------------------------------------------------------------------------
    -- Architecture-level attribute: disable vendor-provided TMR insertion.
    -- Manual TMR is already in place below.
    -----------------------------------------------------------------------------------------------
    attribute syn_radhardlevel of struct : architecture is SynRadhardlevel_None_c;

    -----------------------------------------------------------------------------------------------
    -- Synthesis attributes - preserve registers (prevent merging of TMR copies)
    -----------------------------------------------------------------------------------------------
    attribute dont_touch of DataLatchInA  : signal is DontTouch_SuppressChanges_c;
    attribute dont_touch of DataLatchInB  : signal is DontTouch_SuppressChanges_c;
    attribute dont_touch of DataLatchInC  : signal is DontTouch_SuppressChanges_c;
    attribute dont_touch of Out_Data_SigA : signal is DontTouch_SuppressChanges_c;
    attribute dont_touch of Out_Data_SigB : signal is DontTouch_SuppressChanges_c;
    attribute dont_touch of Out_Data_SigC : signal is DontTouch_SuppressChanges_c;
    attribute dont_touch of OutValid      : signal is DontTouch_SuppressChanges_c;

    attribute dont_merge of DataLatchInA  : signal is DontMerge_SuppressChanges_c;
    attribute dont_merge of DataLatchInB  : signal is DontMerge_SuppressChanges_c;
    attribute dont_merge of DataLatchInC  : signal is DontMerge_SuppressChanges_c;
    attribute dont_merge of Out_Data_SigA : signal is DontMerge_SuppressChanges_c;
    attribute dont_merge of Out_Data_SigB : signal is DontMerge_SuppressChanges_c;
    attribute dont_merge of Out_Data_SigC : signal is DontMerge_SuppressChanges_c;
    attribute dont_merge of OutValid      : signal is DontMerge_SuppressChanges_c;

    attribute preserve of DataLatchInA  : signal is Preserve_SuppressChanges_c;
    attribute preserve of DataLatchInB  : signal is Preserve_SuppressChanges_c;
    attribute preserve of DataLatchInC  : signal is Preserve_SuppressChanges_c;
    attribute preserve of Out_Data_SigA : signal is Preserve_SuppressChanges_c;
    attribute preserve of Out_Data_SigB : signal is Preserve_SuppressChanges_c;
    attribute preserve of Out_Data_SigC : signal is Preserve_SuppressChanges_c;
    attribute preserve of OutValid      : signal is Preserve_SuppressChanges_c;

    attribute syn_preserve of DataLatchInA  : signal is SynPreserve_SuppressChanges_c;
    attribute syn_preserve of DataLatchInB  : signal is SynPreserve_SuppressChanges_c;
    attribute syn_preserve of DataLatchInC  : signal is SynPreserve_SuppressChanges_c;
    attribute syn_preserve of Out_Data_SigA : signal is SynPreserve_SuppressChanges_c;
    attribute syn_preserve of Out_Data_SigB : signal is SynPreserve_SuppressChanges_c;
    attribute syn_preserve of Out_Data_SigC : signal is SynPreserve_SuppressChanges_c;
    attribute syn_preserve of OutValid      : signal is SynPreserve_SuppressChanges_c;

    attribute syn_keep of DataLatchInA  : signal is SynKeep_SuppressChanges_c;
    attribute syn_keep of DataLatchInB  : signal is SynKeep_SuppressChanges_c;
    attribute syn_keep of DataLatchInC  : signal is SynKeep_SuppressChanges_c;
    attribute syn_keep of Out_Data_SigA : signal is SynKeep_SuppressChanges_c;
    attribute syn_keep of Out_Data_SigB : signal is SynKeep_SuppressChanges_c;
    attribute syn_keep of Out_Data_SigC : signal is SynKeep_SuppressChanges_c;
    attribute syn_keep of OutValid      : signal is SynKeep_SuppressChanges_c;

begin

    -----------------------------------------------------------------------------------------------
    -- Reset crossing (TMR-hardened)
    -----------------------------------------------------------------------------------------------
    i_rst : entity work.olo_ft_cc_reset
        port map (
            A_Clk    => In_Clk,
            A_RstIn  => In_RstIn,
            A_RstOut => RstInI,
            B_Clk    => Out_Clk,
            B_RstIn  => Out_RstIn,
            B_RstOut => RstOutI
        );

    In_RstOut  <= RstInI;
    Out_RstOut <= RstOutI;

    -----------------------------------------------------------------------------------------------
    -- Valid crossing (TMR-hardened toggle synchronizer)
    -----------------------------------------------------------------------------------------------
    i_vld : entity work.olo_ft_private_cc_toggle
        generic map (
            SyncStages_g => SyncStages_g
        )
        port map (
            In_Clk    => In_Clk,
            In_Rst    => RstInI,
            In_Pulse  => In_Valid,
            Out_Clk   => Out_Clk,
            Out_Rst   => RstOutI,
            Out_Pulse => VldOutI
        );

    -----------------------------------------------------------------------------------------------
    -- Data transmit side (A)
    -----------------------------------------------------------------------------------------------
    -- Majority voter: (A*B) + (B*C) + (A*C)
    DataLatchInVote <= (DataLatchInA and DataLatchInB) or
                       (DataLatchInB and DataLatchInC) or
                       (DataLatchInA and DataLatchInC);

    p_data_a : process (In_Clk) is
    begin
        if rising_edge(In_Clk) then
            if In_Valid = '1' then
                DataLatchInA <= In_Data;
                DataLatchInB <= In_Data;
                DataLatchInC <= In_Data;
            else
                -- Hold the voted value, which repairs an upset copy
                DataLatchInA <= DataLatchInVote;
                DataLatchInB <= DataLatchInVote;
                DataLatchInC <= DataLatchInVote;
            end if;
        end if;
    end process;

    -----------------------------------------------------------------------------------------------
    -- Data receive side (B)
    -----------------------------------------------------------------------------------------------
    OutDataVote <= (Out_Data_SigA and Out_Data_SigB) or
                   (Out_Data_SigB and Out_Data_SigC) or
                   (Out_Data_SigA and Out_Data_SigC);

    p_data_b : process (Out_Clk) is
    begin
        if rising_edge(Out_Clk) then
            OutValid <= (others => VldOutI);
            if VldOutI = '1' then
                -- Each copy samples its own transmit-side copy (stable while the valid crosses)
                Out_Data_SigA <= DataLatchInA;
                Out_Data_SigB <= DataLatchInB;
                Out_Data_SigC <= DataLatchInC;
            else
                -- Hold the voted value, which repairs an upset copy
                Out_Data_SigA <= OutDataVote;
                Out_Data_SigB <= OutDataVote;
                Out_Data_SigC <= OutDataVote;
            end if;
            -- Reset
            if RstOutI = '1' then
                OutValid <= (others => '0');
            end if;
        end if;
    end process;

    Out_Data  <= OutDataVote;
    Out_Valid <= (OutValid(0) and OutValid(1)) or
                 (OutValid(1) and OutValid(2)) or
                 (OutValid(0) and OutValid(2));

end architecture;
