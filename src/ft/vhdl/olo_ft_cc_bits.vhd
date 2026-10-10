---------------------------------------------------------------------------------------------------
-- Copyright (c) 2026 by Julian Schneider
-- Authors: Julian Schneider
---------------------------------------------------------------------------------------------------

---------------------------------------------------------------------------------------------------
-- Description
---------------------------------------------------------------------------------------------------
-- TMR-hardened multi-bit clock domain crossing for level signals: three independent
-- synchronizer chains with a per-bit majority voter provide single-SEU immunity (long-pulse
-- TMR synchronizer from Li, Nelson, Wirthlin, IEEE TNS 2010). It is the fault-tolerant
-- counterpart of olo_base_cc_bits with the same interface.
--
-- Documentation:
-- https://github.com/open-logic/open-logic/blob/main/doc/ft/olo_ft_cc_bits.md
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

entity olo_ft_cc_bits is
    generic (
        Width_g      : positive              := 1;
        SyncStages_g : positive range 2 to 4 := 2
    );
    port (
        -- Input clock domain
        In_Clk   : in    std_logic;
        In_Rst   : in    std_logic := '0';
        In_Data  : in    std_logic_vector(Width_g - 1 downto 0);
        -- Output clock domain
        Out_Clk  : in    std_logic;
        Out_Rst  : in    std_logic := '0';
        Out_Data : out   std_logic_vector(Width_g - 1 downto 0)
    );
end entity;

---------------------------------------------------------------------------------------------------
-- Architecture
---------------------------------------------------------------------------------------------------

architecture struct of olo_ft_cc_bits is

    -----------------------------------------------------------------------------------------------
    -- Types
    -----------------------------------------------------------------------------------------------
    -- One entry per TMR copy (0 = A, 1 = B, 2 = C)
    type Tmr_t is array (0 to 2) of std_logic_vector(Width_g - 1 downto 0);

    -----------------------------------------------------------------------------------------------
    -- Signals
    -----------------------------------------------------------------------------------------------
    -- Per-copy synchronizer output (= last sync stage of each chain)
    signal RcvSig : Tmr_t;

    -- Input clock signal (required for automatic constraining in Vivado)
    signal In_Clk_Sig : std_logic;

    -----------------------------------------------------------------------------------------------
    -- Architecture-level attribute: disable vendor-provided TMR insertion.
    -- Manual TMR is already in place below. Without this attribute, tools like Synplify for
    -- Microchip Libero would apply their own TMR on top of the triplicated registers.
    -----------------------------------------------------------------------------------------------
    attribute syn_radhardlevel of struct : architecture is SynRadhardlevel_None_c;

    -----------------------------------------------------------------------------------------------
    -- Synthesis attributes automatic constraining (AMD only)
    -----------------------------------------------------------------------------------------------
    attribute dont_touch of In_Clk_Sig : signal is DontTouch_SuppressChanges_c;
    attribute keep of In_Clk_Sig       : signal is Keep_SuppressChanges_c;

begin

    In_Clk_Sig <= In_Clk;

    -----------------------------------------------------------------------------------------------
    -- Three independent synchronizer chains (structure of olo_base_cc_bits)
    -----------------------------------------------------------------------------------------------
    g_copy : for i in 0 to 2 generate

        type SyncStages_t is array (0 to SyncStages_g - 2) of std_logic_vector(Width_g - 1 downto 0);

        -- Synchronizer registers of this copy
        signal RegIn : std_logic_vector(Width_g - 1 downto 0) := (others => '0');
        signal Reg0  : std_logic_vector(Width_g - 1 downto 0) := (others => '0');
        signal RegN  : SyncStages_t                           := (others => (others => '0'));

        -- Synthesis attributes - shiftregister extraction (prevent SRL inference)
        attribute shreg_extract of Reg0  : signal is ShregExtract_SuppressExtraction_c;
        attribute shreg_extract of RegN  : signal is ShregExtract_SuppressExtraction_c;
        attribute shreg_extract of RegIn : signal is ShregExtract_SuppressExtraction_c;

        attribute syn_srlstyle of Reg0  : signal is SynSrlstyle_FlipFlops_c;
        attribute syn_srlstyle of RegN  : signal is SynSrlstyle_FlipFlops_c;
        attribute syn_srlstyle of RegIn : signal is SynSrlstyle_FlipFlops_c;

        -- Synthesis attributes - preserve registers (prevent merging of TMR copies)
        attribute dont_merge of Reg0  : signal is DontMerge_SuppressChanges_c;
        attribute dont_merge of RegN  : signal is DontMerge_SuppressChanges_c;
        attribute dont_merge of RegIn : signal is DontMerge_SuppressChanges_c;

        attribute preserve of Reg0  : signal is Preserve_SuppressChanges_c;
        attribute preserve of RegN  : signal is Preserve_SuppressChanges_c;
        attribute preserve of RegIn : signal is Preserve_SuppressChanges_c;

        attribute syn_preserve of Reg0  : signal is SynPreserve_SuppressChanges_c;
        attribute syn_preserve of RegN  : signal is SynPreserve_SuppressChanges_c;
        attribute syn_preserve of RegIn : signal is SynPreserve_SuppressChanges_c;

        attribute syn_keep of Reg0  : signal is SynKeep_SuppressChanges_c;
        attribute syn_keep of RegN  : signal is SynKeep_SuppressChanges_c;
        attribute syn_keep of RegIn : signal is SynKeep_SuppressChanges_c;

        -- Synthesis attributes - async registers (metastability handling)
        attribute async_reg of Reg0  : signal is AsyncReg_TreatAsync_c;
        attribute async_reg of RegN  : signal is AsyncReg_TreatAsync_c;
        attribute async_reg of RegIn : signal is AsyncReg_TreatAsync_c;

    begin

        -- Input register in the sender's domain
        p_inff : process (In_Clk) is
        begin
            if rising_edge(In_Clk) then
                RegIn <= In_Data;
                if In_Rst = '1' then
                    RegIn <= (others => '0');
                end if;
            end if;
        end process;

        -- Synchronizer chain in the receiver's domain
        p_outff : process (Out_Clk) is
        begin
            if rising_edge(Out_Clk) then
                -- First two stages
                Reg0    <= RegIn;
                RegN(0) <= Reg0;

                -- Remaining stages
                for s in 1 to RegN'high loop
                    RegN(s) <= RegN(s - 1);
                end loop;

                -- Reset
                if Out_Rst = '1' then
                    Reg0 <= (others => '0');
                    RegN <= (others => (others => '0'));
                end if;
            end if;
        end process;

        -- Synchronizer output of this copy (= last sync stage)
        RcvSig(i) <= RegN(RegN'high);

    end generate;

    -----------------------------------------------------------------------------------------------
    -- Per-bit majority voter: Out[i] = (A*B) + (B*C) + (A*C)
    -----------------------------------------------------------------------------------------------
    Out_Data <= (RcvSig(0) and RcvSig(1)) or
                (RcvSig(1) and RcvSig(2)) or
                (RcvSig(0) and RcvSig(2));

end architecture;
