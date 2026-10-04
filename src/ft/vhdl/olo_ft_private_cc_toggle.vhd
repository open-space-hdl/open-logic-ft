---------------------------------------------------------------------------------------------------
-- Copyright (c) 2026 by Julian Schneider
-- Authors: Julian Schneider
---------------------------------------------------------------------------------------------------

---------------------------------------------------------------------------------------------------
-- Description
---------------------------------------------------------------------------------------------------
-- TMR-hardened, toggle-based single-pulse clock crossing without reset crossing. Internal building
-- block of olo_ft_cc_simple, olo_ft_cc_status and olo_ft_cc_handshake.
--
-- Documentation:
-- https://github.com/open-logic/open-logic/blob/main/doc/ft/olo_ft_private_cc_toggle.md
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
entity olo_ft_private_cc_toggle is
    generic (
        SyncStages_g : positive range 2 to 4 := 2
    );
    port (
        -- Input clock domain
        In_Clk    : in    std_logic;
        In_Rst    : in    std_logic;
        In_Pulse  : in    std_logic;
        -- Output clock domain
        Out_Clk   : in    std_logic;
        Out_Rst   : in    std_logic;
        Out_Pulse : out   std_logic
    );
end entity;

---------------------------------------------------------------------------------------------------
-- Architecture
---------------------------------------------------------------------------------------------------
architecture struct of olo_ft_private_cc_toggle is

    -----------------------------------------------------------------------------------------------
    -- Signals
    -----------------------------------------------------------------------------------------------
    -- TMR copies of the toggle state (index 0 = A, 1 = B, 2 = C)
    signal ToggleLast    : std_logic_vector(0 to 2) := (others => '0');
    signal ToggleOutLast : std_logic_vector(0 to 2) := (others => '0');

    -- Voted values
    signal ToggleLastVote    : std_logic;
    signal ToggleOutLastVote : std_logic;

    -- Toggle signal before and after the crossing
    signal ToggleIn  : std_logic;
    signal ToggleOut : std_logic;

    -----------------------------------------------------------------------------------------------
    -- Architecture-level attribute: disable vendor-provided TMR insertion.
    -- Manual TMR is already in place below.
    -----------------------------------------------------------------------------------------------
    attribute syn_radhardlevel of struct : architecture is SynRadhardlevel_None_c;

    -----------------------------------------------------------------------------------------------
    -- Synthesis attributes - preserve registers (prevent merging of TMR copies)
    -----------------------------------------------------------------------------------------------
    attribute dont_touch of ToggleLast    : signal is DontTouch_SuppressChanges_c;
    attribute dont_touch of ToggleOutLast : signal is DontTouch_SuppressChanges_c;

    attribute dont_merge of ToggleLast    : signal is DontMerge_SuppressChanges_c;
    attribute dont_merge of ToggleOutLast : signal is DontMerge_SuppressChanges_c;

    attribute preserve of ToggleLast    : signal is Preserve_SuppressChanges_c;
    attribute preserve of ToggleOutLast : signal is Preserve_SuppressChanges_c;

    attribute syn_preserve of ToggleLast    : signal is SynPreserve_SuppressChanges_c;
    attribute syn_preserve of ToggleOutLast : signal is SynPreserve_SuppressChanges_c;

    attribute syn_keep of ToggleLast    : signal is SynKeep_SuppressChanges_c;
    attribute syn_keep of ToggleOutLast : signal is SynKeep_SuppressChanges_c;

begin

    -----------------------------------------------------------------------------------------------
    -- Input domain: toggle on every pulse
    -----------------------------------------------------------------------------------------------
    -- Majority voter: (A*B) + (B*C) + (A*C)
    ToggleLastVote <= (ToggleLast(0) and ToggleLast(1)) or
                      (ToggleLast(1) and ToggleLast(2)) or
                      (ToggleLast(0) and ToggleLast(2));

    -- Combinatorial because the register is in olo_ft_cc_bits
    ToggleIn <= ToggleLastVote xor In_Pulse;

    p_in : process (In_Clk) is
    begin
        if rising_edge(In_Clk) then
            -- All copies load the voted value, which repairs an upset copy
            ToggleLast <= (others => ToggleIn);

            -- Reset
            if In_Rst = '1' then
                ToggleLast <= (others => '0');
            end if;
        end if;
    end process;

    -----------------------------------------------------------------------------------------------
    -- Crossing (TMR synchronizer chains with majority voter)
    -----------------------------------------------------------------------------------------------
    i_sync : entity work.olo_ft_cc_bits
        generic map (
            Width_g      => 1,
            SyncStages_g => SyncStages_g
        )
        port map (
            In_Clk      => In_Clk,
            In_Rst      => In_Rst,
            In_Data(0)  => ToggleIn,
            Out_Clk     => Out_Clk,
            Out_Rst     => Out_Rst,
            Out_Data(0) => ToggleOut
        );

    -----------------------------------------------------------------------------------------------
    -- Output domain: edge detection
    -----------------------------------------------------------------------------------------------
    ToggleOutLastVote <= (ToggleOutLast(0) and ToggleOutLast(1)) or
                         (ToggleOutLast(1) and ToggleOutLast(2)) or
                         (ToggleOutLast(0) and ToggleOutLast(2));

    p_out : process (Out_Clk) is
    begin
        if rising_edge(Out_Clk) then
            ToggleOutLast <= (others => ToggleOut);

            -- Reset
            if Out_Rst = '1' then
                ToggleOutLast <= (others => '0');
            end if;
        end if;
    end process;

    Out_Pulse <= ToggleOutLastVote xor ToggleOut;

end architecture;
