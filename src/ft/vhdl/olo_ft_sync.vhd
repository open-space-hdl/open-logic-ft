---------------------------------------------------------------------------------------------------
-- Copyright (c) 2026 by Julian Schneider
-- Authors: Julian Schneider
---------------------------------------------------------------------------------------------------

---------------------------------------------------------------------------------------------------
-- Description
---------------------------------------------------------------------------------------------------
-- TMR-hardened synchronizer for asynchronous input signals with the interface and behavior of
-- olo_intf_sync: three independent synchronizer chains per bit and a majority voter.
--
-- Documentation:
-- https://github.com/open-logic/open-logic/blob/main/doc/ft/olo_ft_sync.md
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
entity olo_ft_sync is
    generic (
        Width_g      : positive              := 1;
        RstLevel_g   : std_logic             := '0';
        SyncStages_g : positive range 2 to 4 := 2
    );
    port (
        -- control signals
        Clk         : in    std_logic;
        Rst         : in    std_logic := '0';
        -- Input clock domain
        DataAsync   : in    std_logic_vector(Width_g - 1 downto 0);
        DataSync    : out   std_logic_vector(Width_g - 1 downto 0)
    );
end entity;

---------------------------------------------------------------------------------------------------
-- Architecture
---------------------------------------------------------------------------------------------------
architecture struct of olo_ft_sync is

    -- Last synchronizer stage of each TMR copy (0 = A, 1 = B, 2 = C)
    type Tmr_t is array (0 to 2) of std_logic_vector(Width_g - 1 downto 0);

    signal RcvSig : Tmr_t;

    -----------------------------------------------------------------------------------------------
    -- Architecture-level attribute: disable vendor-provided TMR insertion.
    -- Manual TMR is already in place below.
    -----------------------------------------------------------------------------------------------
    attribute syn_radhardlevel of struct : architecture is SynRadhardlevel_None_c;

begin

    -----------------------------------------------------------------------------------------------
    -- Three independent synchronizer chains (structure of olo_intf_sync)
    -----------------------------------------------------------------------------------------------
    g_copy : for i in 0 to 2 generate

        type SyncStages_t is array(0 to SyncStages_g - 2) of std_logic_vector(Width_g - 1 downto 0);

        signal Reg0 : std_logic_vector(Width_g - 1 downto 0) := (others => RstLevel_g);
        signal RegN : SyncStages_t                           := (others => (others => RstLevel_g));

        -- Synthesis attributes - suppress shift register extraction
        attribute shreg_extract of Reg0 : signal is ShregExtract_SuppressExtraction_c;
        attribute shreg_extract of RegN : signal is ShregExtract_SuppressExtraction_c;
        attribute syn_srlstyle of Reg0  : signal is SynSrlstyle_FlipFlops_c;
        attribute syn_srlstyle of RegN  : signal is SynSrlstyle_FlipFlops_c;

        -- Synthesis attributes - preserve registers (prevent merging of TMR copies)
        attribute dont_touch of Reg0   : signal is DontTouch_SuppressChanges_c;
        attribute dont_touch of RegN   : signal is DontTouch_SuppressChanges_c;
        attribute dont_merge of Reg0   : signal is DontMerge_SuppressChanges_c;
        attribute dont_merge of RegN   : signal is DontMerge_SuppressChanges_c;
        attribute preserve of Reg0     : signal is Preserve_SuppressChanges_c;
        attribute preserve of RegN     : signal is Preserve_SuppressChanges_c;
        attribute syn_keep of Reg0     : signal is SynKeep_SuppressChanges_c;
        attribute syn_keep of RegN     : signal is SynKeep_SuppressChanges_c;
        attribute syn_preserve of Reg0 : signal is SynPreserve_SuppressChanges_c;
        attribute syn_preserve of RegN : signal is SynPreserve_SuppressChanges_c;

        -- Synthesis attributes - asynchronous registers
        attribute async_reg of Reg0 : signal is AsyncReg_TreatAsync_c;
        attribute async_reg of RegN : signal is AsyncReg_TreatAsync_c;

    begin

        p_outff : process (Clk) is
        begin
            if rising_edge(Clk) then
                -- *** Synchronization ***
                -- First two stages
                Reg0    <= DataAsync;
                RegN(0) <= Reg0;

                -- Loop through remaining stages
                for s in 1 to RegN'high loop
                    RegN(s) <= RegN(s - 1);
                end loop;

                -- *** Reset ***
                if Rst = '1' then
                    Reg0 <= (others => RstLevel_g);
                    RegN <= (others => (others => RstLevel_g));
                end if;
            end if;
        end process;

        RcvSig(i) <= RegN(RegN'high);

    end generate;

    -----------------------------------------------------------------------------------------------
    -- Majority voter per bit: (A*B) + (B*C) + (A*C)
    -----------------------------------------------------------------------------------------------
    DataSync <= (RcvSig(0) and RcvSig(1)) or
                (RcvSig(1) and RcvSig(2)) or
                (RcvSig(0) and RcvSig(2));

end architecture;
