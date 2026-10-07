---------------------------------------------------------------------------------------------------
-- Copyright (c) 2026 by Julian Schneider
-- Authors: Julian Schneider
---------------------------------------------------------------------------------------------------

---------------------------------------------------------------------------------------------------
-- Description
---------------------------------------------------------------------------------------------------
-- TMR-hardened pulse clock domain crossing with the semantics of olo_base_cc_pulse: every input
-- pulse toggles a TMR-protected level that crosses through TMR synchronizer chains and is converted
-- back into a single-cycle output pulse. The design contains no latches.
--
-- Documentation:
-- https://github.com/open-logic/open-logic/blob/main/doc/ft/olo_ft_cc_pulse.md
--
-- Note: The link points to the documentation of the latest release. If you
--       use an older version, the documentation might not match the code.

---------------------------------------------------------------------------------------------------
-- Libraries
---------------------------------------------------------------------------------------------------
library ieee;
    use ieee.std_logic_1164.all;
    use ieee.numeric_std.all;

---------------------------------------------------------------------------------------------------
-- Entity
---------------------------------------------------------------------------------------------------
entity olo_ft_cc_pulse is
    generic (
        NumPulses_g  : positive              := 1;
        SyncStages_g : positive range 2 to 4 := 2
    );
    port (
        -- Input clock domain
        In_Clk     : in    std_logic;
        In_RstIn   : in    std_logic := '0';
        In_RstOut  : out   std_logic;
        In_Pulse   : in    std_logic_vector(NumPulses_g - 1 downto 0);
        -- Output clock domain
        Out_Clk    : in    std_logic;
        Out_RstIn  : in    std_logic := '0';
        Out_RstOut : out   std_logic;
        Out_Pulse  : out   std_logic_vector(NumPulses_g - 1 downto 0)
    );
end entity;

---------------------------------------------------------------------------------------------------
-- Architecture
---------------------------------------------------------------------------------------------------
architecture struct of olo_ft_cc_pulse is

    -- Resets (crossed by olo_ft_cc_reset)
    signal RstInI  : std_logic;
    signal RstOutI : std_logic;

begin

    -----------------------------------------------------------------------------------------------
    -- Reset crossing between the two clock domains
    -----------------------------------------------------------------------------------------------
    i_rst : entity work.olo_ft_cc_reset
        generic map (
            SyncStages_g => SyncStages_g
        )
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
    -- One TMR toggle crossing per pulse channel
    -----------------------------------------------------------------------------------------------
    g_pulse : for i in 0 to NumPulses_g - 1 generate

        i_toggle : entity work.olo_ft_private_cc_toggle
            generic map (
                SyncStages_g => SyncStages_g
            )
            port map (
                In_Clk    => In_Clk,
                In_Rst    => RstInI,
                In_Pulse  => In_Pulse(i),
                Out_Clk   => Out_Clk,
                Out_Rst   => RstOutI,
                Out_Pulse => Out_Pulse(i)
            );

    end generate;

end architecture;
