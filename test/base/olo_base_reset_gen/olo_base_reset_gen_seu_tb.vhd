---------------------------------------------------------------------------------------------------
-- Copyright (c) 2026 by Julian Schneider
-- Authors: Julian Schneider
---------------------------------------------------------------------------------------------------

---------------------------------------------------------------------------------------------------
-- Description
---------------------------------------------------------------------------------------------------
-- Single-event upset tests for olo_base_reset_gen. Upsets are injected by forcing the first stage of
-- the reset synchronizer chains through VHDL-2008 external names.

---------------------------------------------------------------------------------------------------
-- Libraries
---------------------------------------------------------------------------------------------------
library ieee;
    use ieee.std_logic_1164.all;
    use ieee.numeric_std.all;

library vunit_lib;
    context vunit_lib.vunit_context;

library olo;
    use olo.olo_base_pkg_math.all;

---------------------------------------------------------------------------------------------------
-- Entity
---------------------------------------------------------------------------------------------------
-- vunit: run_all_in_same_sim
entity olo_base_reset_gen_seu_tb is
    generic (
        runner_cfg         : string;
        AsyncResetOutput_g : boolean := false;
        SyncTmr_g          : boolean := true
    );
end entity;

architecture sim of olo_base_reset_gen_seu_tb is

    -----------------------------------------------------------------------------------------------
    -- Constants
    -----------------------------------------------------------------------------------------------
    constant Chains_c     : integer := choose(SyncTmr_g, 3, 1);
    constant SyncStages_c : integer := 2;

    -----------------------------------------------------------------------------------------------
    -- TB Defnitions
    -----------------------------------------------------------------------------------------------
    constant Clk_Frequency_c : real := 100.0e6;
    constant Clk_Period_c    : time := (1 sec) / Clk_Frequency_c;

    -- Upset injection
    type Reg_t is (UpsetRstSyncChain, UpsetDsSync);

    -----------------------------------------------------------------------------------------------
    -- Interface Signals
    -----------------------------------------------------------------------------------------------
    signal Clk    : std_logic := '0';
    signal RstOut : std_logic;
    signal RstIn  : std_logic := '0';

    -----------------------------------------------------------------------------------------------
    -- TB Signals
    -----------------------------------------------------------------------------------------------
    signal RstPulses   : natural                  := 0;
    signal UpsetReq    : natural                  := 0;
    signal UpsetChains : std_logic_vector(0 to 2) := "000";
    signal UpsetReg    : Reg_t                    := UpsetRstSyncChain;

    -----------------------------------------------------------------------------------------------
    -- Procedures
    -----------------------------------------------------------------------------------------------
    -- Chain mask with only chain c selected
    function oneChain (c : natural) return std_logic_vector is
        variable Mask_v : std_logic_vector(0 to 2) := "000";
    begin
        Mask_v(c) := '1';
        return Mask_v;
    end function;

    -- Upset of the first stage of a synchronizer in the selected chains for one clock cycle
    procedure upset (
        Chains             : std_logic_vector(0 to 2);
        Reg                : Reg_t;
        signal UpsetChains : out std_logic_vector(0 to 2);
        signal UpsetReg    : out Reg_t;
        signal UpsetReq    : inout natural) is
    begin
        UpsetChains <= Chains;
        UpsetReg    <= Reg;
        UpsetReq    <= UpsetReq + 1;
        wait for 20 * Clk_Period_c;
    end procedure;

begin

    -----------------------------------------------------------------------------------------------
    -- DUT
    -----------------------------------------------------------------------------------------------
    i_dut : entity olo.olo_base_reset_gen
        generic map (
            AsyncResetOutput_g => AsyncResetOutput_g,
            SyncStages_g       => SyncStages_c,
            SyncTmr_g          => SyncTmr_g
        )
        port map (
            Clk    => Clk,
            RstOut => RstOut,
            RstIn  => RstIn
        );

    -----------------------------------------------------------------------------------------------
    -- Clock
    -----------------------------------------------------------------------------------------------
    Clk <= not Clk after 0.5 * Clk_Period_c;

    -----------------------------------------------------------------------------------------------
    -- TB Control
    -----------------------------------------------------------------------------------------------
    test_runner_watchdog(runner, 1 ms);

    p_control : process is
        variable Pulses_v : natural;
    begin
        test_runner_setup(runner, runner_cfg);

        while test_suite loop

            -- Reset
            wait until rising_edge(Clk);
            RstIn    <= '1';
            wait until rising_edge(Clk);
            RstIn    <= '0';
            wait for 20 * Clk_Period_c;
            check_equal(RstOut, '0', "RstOut not released");
            Pulses_v := RstPulses;

            -- Single upsets in every chain and synchronizer
            if run("Seu-Single") then

                for c in 0 to Chains_c - 1 loop
                    upset(oneChain(c), UpsetRstSyncChain, UpsetChains, UpsetReg, UpsetReq);
                    if not AsyncResetOutput_g then
                        upset(oneChain(c), UpsetDsSync, UpsetChains, UpsetReg, UpsetReq);
                    end if;
                end loop;

                if SyncTmr_g then
                    check_equal(RstPulses, Pulses_v, "Spurious reset");
                else
                    -- Without triplication, the upsets are visible (validates the injection)
                    check_equal(RstPulses, Pulses_v + choose(AsyncResetOutput_g, 1, 2),
                                "Upset not visible without triplication");
                end if;

            -- Two upsets at the same time are visible (validates the injection into every chain)
            elsif run("Seu-Double") then
                if SyncTmr_g then
                    upset("110", UpsetRstSyncChain, UpsetChains, UpsetReg, UpsetReq);
                    upset("011", UpsetRstSyncChain, UpsetChains, UpsetReg, UpsetReq);
                    upset("101", UpsetRstSyncChain, UpsetChains, UpsetReg, UpsetReq);
                    check_equal(RstPulses, Pulses_v + 3, "Double upset not visible");
                    if not AsyncResetOutput_g then
                        upset("110", UpsetDsSync, UpsetChains, UpsetReg, UpsetReq);
                        upset("011", UpsetDsSync, UpsetChains, UpsetReg, UpsetReq);
                        upset("101", UpsetDsSync, UpsetChains, UpsetReg, UpsetReq);
                        check_equal(RstPulses, Pulses_v + 6, "Double upset not visible");
                    end if;
                end if;
            end if;

        end loop;

        -- TB done
        test_runner_cleanup(runner);
    end process;

    -----------------------------------------------------------------------------------------------
    -- Reset pulse counter
    -----------------------------------------------------------------------------------------------
    p_count : process (RstOut) is
    begin
        if rising_edge(RstOut) then
            RstPulses <= RstPulses + 1;
        end if;
    end process;

    -----------------------------------------------------------------------------------------------
    -- Upset injection, chain 0
    -----------------------------------------------------------------------------------------------
    p_upset_chain0 : process is
        alias RstSyncChain is << signal .olo_base_reset_gen_seu_tb.i_dut.RstSyncChain : std_logic_vector(2 downto 0) >>;
        alias DsSync       is << signal .olo_base_reset_gen_seu_tb.i_dut.DsSync :
            std_logic_vector(SyncStages_c - 1 downto 0) >>;
    begin
        wait on UpsetReq;
        if UpsetChains(0) = '1' then
            wait until rising_edge(Clk);
            wait for 1 ps;
            if UpsetReg = UpsetRstSyncChain then
                RstSyncChain <= force RstSyncChain(2 downto 1) & not RstSyncChain(0);
                wait until rising_edge(Clk);
                RstSyncChain <= release;
            else
                DsSync <= force DsSync(SyncStages_c - 1 downto 1) & not DsSync(0);
                wait until rising_edge(Clk);
                DsSync <= release;
            end if;
        end if;
    end process;

    -----------------------------------------------------------------------------------------------
    -- Upset injection, chains 1 and 2
    -----------------------------------------------------------------------------------------------
    g_tmr : if SyncTmr_g generate

        g_chain : for c in 1 to 2 generate

            p_upset : process is
                alias RstSyncChain is << signal .olo_base_reset_gen_seu_tb.i_dut.g_tmr.g_chain(c).RstSyncChain :
                    std_logic_vector(2 downto 0) >>;
                alias DsSync       is << signal .olo_base_reset_gen_seu_tb.i_dut.g_tmr.g_chain(c).DsSync :
                    std_logic_vector(SyncStages_c - 1 downto 0) >>;
            begin
                wait on UpsetReq;
                if UpsetChains(c) = '1' then
                    wait until rising_edge(Clk);
                    wait for 1 ps;
                    if UpsetReg = UpsetRstSyncChain then
                        RstSyncChain <= force RstSyncChain(2 downto 1) & not RstSyncChain(0);
                        wait until rising_edge(Clk);
                        RstSyncChain <= release;
                    else
                        DsSync <= force DsSync(SyncStages_c - 1 downto 1) & not DsSync(0);
                        wait until rising_edge(Clk);
                        DsSync <= release;
                    end if;
                end if;
            end process;

        end generate;

    end generate;

end architecture;
