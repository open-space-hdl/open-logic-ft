---------------------------------------------------------------------------------------------------
-- Copyright (c) 2026 by Julian Schneider
-- Authors: Julian Schneider
---------------------------------------------------------------------------------------------------

---------------------------------------------------------------------------------------------------
-- Description
---------------------------------------------------------------------------------------------------
-- TMR-hardened clock crossing for data with Valid/Ready handshake. It is the fault-tolerant
-- counterpart of olo_base_cc_handshake with the same interface.
--
-- Documentation:
-- https://github.com/open-logic/open-logic/blob/main/doc/ft/olo_ft_cc_handshake.md
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
entity olo_ft_cc_handshake is
    generic (
        Width_g         : positive;
        ReadyRstState_g : std_logic             := '1';
        SyncStages_g    : positive range 2 to 4 := 2
    );
    port (
        In_Clk      : in    std_logic;
        In_RstIn    : in    std_logic := '0';
        In_RstOut   : out   std_logic;
        In_Data     : in    std_logic_vector(Width_g - 1 downto 0);
        In_Valid    : in    std_logic := '1';
        In_Ready    : out   std_logic;
        Out_Clk     : in    std_logic;
        Out_RstIn   : in    std_logic := '0';
        Out_RstOut  : out   std_logic;
        Out_Data    : out   std_logic_vector(Width_g - 1 downto 0);
        Out_Valid   : out   std_logic;
        Out_Ready   : in    std_logic := '1'
    );
end entity;

---------------------------------------------------------------------------------------------------
-- Architecture
---------------------------------------------------------------------------------------------------
architecture rtl of olo_ft_cc_handshake is

    -----------------------------------------------------------------------------------------------
    -- Signals
    -----------------------------------------------------------------------------------------------
    -- Input Domain Signals
    signal RstInI        : std_logic;
    signal In_ReadyI     : std_logic;
    signal InLatched     : std_logic_vector(0 to 2) := (others => '0'); -- TMR copies (0 = A, 1 = B, 2 = C)
    signal InLatchedVote : std_logic;
    signal InTransaction : std_logic;
    signal InAck         : std_logic;

    -- Output Domain Signals
    signal RstOutI        : std_logic;
    signal OutTransaction : std_logic;
    signal OutLatched     : std_logic_vector(0 to 2) := (others => '0'); -- TMR copies (0 = A, 1 = B, 2 = C)
    signal OutLatchedVote : std_logic;
    signal OutAck         : std_logic;
    signal Out_ValidI     : std_logic;

    -----------------------------------------------------------------------------------------------
    -- Architecture-level attribute: disable vendor-provided TMR insertion.
    -- Manual TMR is already in place below.
    -----------------------------------------------------------------------------------------------
    attribute syn_radhardlevel of rtl : architecture is SynRadhardlevel_None_c;

    -----------------------------------------------------------------------------------------------
    -- Synthesis attributes - preserve registers (prevent merging of TMR copies)
    -----------------------------------------------------------------------------------------------
    attribute dont_touch of InLatched  : signal is DontTouch_SuppressChanges_c;
    attribute dont_touch of OutLatched : signal is DontTouch_SuppressChanges_c;

    attribute dont_merge of InLatched  : signal is DontMerge_SuppressChanges_c;
    attribute dont_merge of OutLatched : signal is DontMerge_SuppressChanges_c;

    attribute preserve of InLatched  : signal is Preserve_SuppressChanges_c;
    attribute preserve of OutLatched : signal is Preserve_SuppressChanges_c;

    attribute syn_preserve of InLatched  : signal is SynPreserve_SuppressChanges_c;
    attribute syn_preserve of OutLatched : signal is SynPreserve_SuppressChanges_c;

    attribute syn_keep of InLatched  : signal is SynKeep_SuppressChanges_c;
    attribute syn_keep of OutLatched : signal is SynKeep_SuppressChanges_c;

begin

    -----------------------------------------------------------------------------------------------
    -- Input side
    -----------------------------------------------------------------------------------------------
    -- Majority voter: (A*B) + (B*C) + (A*C)
    InLatchedVote <= (InLatched(0) and InLatched(1)) or
                     (InLatched(1) and InLatched(2)) or
                     (InLatched(0) and InLatched(2));

    p_in : process (In_Clk) is
    begin
        if rising_edge(In_Clk) then

            -- Hold the voted value, which repairs an upset copy
            InLatched <= (others => InLatchedVote);

            -- Ready is set when data was acknowledged
            if InAck = '1' then
                InLatched <= (others => '0');
            end if;

            -- Ready is reset when data was transferred
            -- This clause may override the clause above
            if InTransaction = '1' then
                InLatched <= (others => '1');
            end if;

            -- Reset
            if RstInI = '1' then
                InLatched <= (others => '0');
            end if;
        end if;
    end process;

    In_ReadyI     <= (not InLatchedVote) or InAck when ReadyRstState_g = '1' else
                     ((not InLatchedVote) or InAck) and (not RstInI); -- Actively pull Ready low during reset if required
    InTransaction <= In_Valid and In_ReadyI;
    In_Ready      <= In_ReadyI;

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
            In_Valid    => InTransaction,
            Out_Clk     => Out_Clk,
            Out_RstIn   => Out_RstIn,
            Out_RstOut  => RstOutI,
            Out_Data    => Out_Data,
            Out_Valid   => OutTransaction
        );

    In_RstOut  <= RstInI;
    Out_RstOut <= RstOutI;

    -----------------------------------------------------------------------------------------------
    -- Transfer acknowledge (path out->in)
    -----------------------------------------------------------------------------------------------
    i_bcc : entity work.olo_ft_private_cc_toggle
        generic map (
            SyncStages_g => SyncStages_g
        )
        port map (
            In_Clk    => Out_Clk,
            In_Rst    => RstOutI,
            In_Pulse  => OutAck,
            Out_Clk   => In_Clk,
            Out_Rst   => RstInI,
            Out_Pulse => InAck
        );

    -----------------------------------------------------------------------------------------------
    -- Output side
    -----------------------------------------------------------------------------------------------
    OutLatchedVote <= (OutLatched(0) and OutLatched(1)) or
                      (OutLatched(1) and OutLatched(2)) or
                      (OutLatched(0) and OutLatched(2));

    p_out : process (Out_Clk) is
    begin
        if rising_edge(Out_Clk) then

            -- Latch data if required, otherwise hold the voted value (repairs an upset copy)
            if OutTransaction = '1' and Out_Ready = '0' then
                OutLatched <= (others => '1');
            elsif Out_Ready = '1' then
                OutLatched <= (others => '0');
            else
                OutLatched <= (others => OutLatchedVote);
            end if;

            -- Reset
            if RstOutI = '1' then
                OutLatched <= (others => '0');
            end if;
        end if;
    end process;

    Out_ValidI <= OutTransaction or OutLatchedVote;
    OutAck     <= Out_ValidI and Out_Ready;
    Out_Valid  <= Out_ValidI;

end architecture;
