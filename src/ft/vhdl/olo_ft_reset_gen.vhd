---------------------------------------------------------------------------------------------------
-- Copyright (c) 2026 by Julian Schneider
-- Authors: Julian Schneider
---------------------------------------------------------------------------------------------------

---------------------------------------------------------------------------------------------------
-- Description
---------------------------------------------------------------------------------------------------
-- TMR-hardened reset generator with the interface and behavior of olo_base_reset_gen: triplicated
-- reset synchronizers and pulse prolongation with majority voters, so that a single-event upset
-- neither asserts nor shortens the reset.
--
-- Documentation:
-- https://github.com/open-logic/open-logic/blob/main/doc/ft/olo_ft_reset_gen.md
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
    use work.olo_base_pkg_math.all;
    use work.olo_base_pkg_attribute.all;
    use work.olo_ft_pkg_attribute.all;

---------------------------------------------------------------------------------------------------
-- Entity
---------------------------------------------------------------------------------------------------
entity olo_ft_reset_gen is
    generic (
        RstPulseCycles_g    : positive range 3 to positive'high := 3;
        RstInPolarity_g     : std_logic                         := '1';
        AsyncResetOutput_g  : boolean                           := false;
        SyncStages_g        : positive range 2 to 4             := 2
    );
    port (
        Clk         : in    std_logic;
        RstOut      : out   std_logic;
        RstIn       : in    std_logic := not RstInPolarity_g
    );
end entity;

---------------------------------------------------------------------------------------------------
-- Architecture
---------------------------------------------------------------------------------------------------
architecture struct of olo_ft_reset_gen is

    -----------------------------------------------------------------------------------------------
    -- Constants and Types
    -----------------------------------------------------------------------------------------------
    constant PulseCntMax_c : natural  := max(RstPulseCycles_g-4, 0);
    constant CntBits_c     : positive := max(log2ceil(PulseCntMax_c+1), 1);

    -- One counter per TMR copy (0 = A, 1 = B, 2 = C)
    type Cnt_t is array (0 to 2) of unsigned(CntBits_c-1 downto 0);

    -- Majority voters
    function vote (
        v : std_logic_vector(0 to 2)) return std_logic is
    begin
        return (v(0) and v(1)) or (v(1) and v(2)) or (v(0) and v(2));
    end function;

    function vote (
        c : Cnt_t) return unsigned is
    begin
        return (c(0) and c(1)) or (c(1) and c(2)) or (c(0) and c(2));
    end function;

    -----------------------------------------------------------------------------------------------
    -- Signals
    -----------------------------------------------------------------------------------------------
    -- Outputs of the three reset synchronizer chains
    signal ChainOut : std_logic_vector(0 to 2);
    signal SyncOut  : std_logic_vector(0 to 2);
    signal RstSync  : std_logic;

    -- Pulse prolongation
    signal PulseCnt  : Cnt_t                    := (others => (others => '0'));
    signal RstPulse  : std_logic_vector(0 to 2) := (others => '1');
    signal PulseVote : std_logic;

    -----------------------------------------------------------------------------------------------
    -- Architecture-level attribute: disable vendor-provided TMR insertion.
    -- Manual TMR is already in place below.
    -----------------------------------------------------------------------------------------------
    attribute syn_radhardlevel of struct : architecture is SynRadhardlevel_None_c;

    -----------------------------------------------------------------------------------------------
    -- Synthesis attributes - preserve registers (prevent merging of TMR copies)
    -----------------------------------------------------------------------------------------------
    attribute dont_touch of PulseCnt : signal is DontTouch_SuppressChanges_c;
    attribute dont_touch of RstPulse : signal is DontTouch_SuppressChanges_c;

    attribute dont_merge of PulseCnt : signal is DontMerge_SuppressChanges_c;
    attribute dont_merge of RstPulse : signal is DontMerge_SuppressChanges_c;

    attribute preserve of PulseCnt : signal is Preserve_SuppressChanges_c;
    attribute preserve of RstPulse : signal is Preserve_SuppressChanges_c;

    attribute syn_preserve of PulseCnt : signal is SynPreserve_SuppressChanges_c;
    attribute syn_preserve of RstPulse : signal is SynPreserve_SuppressChanges_c;

    attribute syn_keep of PulseCnt : signal is SynKeep_SuppressChanges_c;
    attribute syn_keep of RstPulse : signal is SynKeep_SuppressChanges_c;

begin

    -----------------------------------------------------------------------------------------------
    -- Three independent reset synchronizers (one per TMR copy), set asynchronously by RstIn
    -----------------------------------------------------------------------------------------------
    g_copy : for i in 0 to 2 generate

        signal RstSyncChain : std_logic_vector(2 downto 0)              := "111";
        signal DsSync       : std_logic_vector(SyncStages_g-1 downto 0) := (others => '1');

        -- Synthesis attributes - suppress shift register extraction
        attribute shreg_extract of RstSyncChain : signal is ShregExtract_SuppressExtraction_c;
        attribute shreg_extract of DsSync       : signal is ShregExtract_SuppressExtraction_c;
        attribute syn_srlstyle of RstSyncChain  : signal is SynSrlstyle_FlipFlops_c;
        attribute syn_srlstyle of DsSync        : signal is SynSrlstyle_FlipFlops_c;

        -- Synthesis attributes - preserve registers (prevent merging of TMR copies)
        attribute dont_touch of RstSyncChain   : signal is DontTouch_SuppressChanges_c;
        attribute dont_touch of DsSync         : signal is DontTouch_SuppressChanges_c;
        attribute dont_merge of RstSyncChain   : signal is DontMerge_SuppressChanges_c;
        attribute dont_merge of DsSync         : signal is DontMerge_SuppressChanges_c;
        attribute preserve of RstSyncChain     : signal is Preserve_SuppressChanges_c;
        attribute preserve of DsSync           : signal is Preserve_SuppressChanges_c;
        attribute syn_preserve of RstSyncChain : signal is SynPreserve_SuppressChanges_c;
        attribute syn_preserve of DsSync       : signal is SynPreserve_SuppressChanges_c;
        attribute syn_keep of RstSyncChain     : signal is SynKeep_SuppressChanges_c;
        attribute syn_keep of DsSync           : signal is SynKeep_SuppressChanges_c;

        -- Synthesis attributes - asynchronous registers
        attribute async_reg of DsSync : signal is AsyncReg_TreatAsync_c;

    begin

        p_rstsync : process (RstIn, Clk) is
        begin
            if RstIn = RstInPolarity_g then
                RstSyncChain <= (others => '1');
            elsif rising_edge(Clk) then
                RstSyncChain <= RstSyncChain(RstSyncChain'left - 1 downto 0) & '0';
            end if;
        end process;

        ChainOut(i) <= RstSyncChain(RstSyncChain'left);

        -- Synchronizer for synchronous assertion
        g_sync : if not AsyncResetOutput_g generate

            p_sync : process (Clk) is
            begin
                if rising_edge(Clk) then
                    DsSync <= DsSync(DsSync'left - 1 downto 0) & RstSyncChain(RstSyncChain'left);
                end if;
            end process;

        end generate;

        SyncOut(i) <= DsSync(DsSync'left);

    end generate;

    -- Asynchronous assertion
    g_async : if AsyncResetOutput_g generate
        RstSync <= vote(ChainOut);
    end generate;

    -- Synchronous assertion
    g_sync : if not AsyncResetOutput_g generate
        RstSync <= vote(SyncOut);
    end generate;

    -----------------------------------------------------------------------------------------------
    -- Prolong reset pulse: every copy loads the next value computed from the voted state, which
    -- repairs an upset copy at the next clock edge
    -----------------------------------------------------------------------------------------------
    g_prolong : if RstPulseCycles_g > 3 generate

        PulseVote <= vote(RstPulse);

        p_prolong : process (Clk) is
            variable CntVote_v : unsigned(CntBits_c-1 downto 0);
        begin
            if rising_edge(Clk) then
                CntVote_v := vote(PulseCnt);

                for i in 0 to 2 loop
                    -- Reset
                    if RstSync = '1' then
                        PulseCnt(i) <= (others => '0');
                        RstPulse(i) <= '1';
                    -- Removal
                    elsif CntVote_v = PulseCntMax_c then
                        PulseCnt(i) <= CntVote_v;
                        RstPulse(i) <= '0';
                    else
                        PulseCnt(i) <= CntVote_v + 1;
                        RstPulse(i) <= PulseVote;
                    end if;
                end loop;

            end if;
        end process;

        -- Asynchronous output
        g_async : if AsyncResetOutput_g generate
            RstOut <= PulseVote or RstSync;
        end generate;

        -- Synchronous output
        g_sync : if not AsyncResetOutput_g generate
            RstOut <= PulseVote;
        end generate;

    end generate;

    g_direct : if RstPulseCycles_g <= 3 generate
        RstOut <= RstSync;
    end generate;

end architecture;
