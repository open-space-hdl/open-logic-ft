---------------------------------------------------------------------------------------------------
-- Copyright (c) 2026 by Julian Schneider
-- Authors: Julian Schneider
---------------------------------------------------------------------------------------------------

---------------------------------------------------------------------------------------------------
-- Description
---------------------------------------------------------------------------------------------------
-- Single-event upset tests for olo_intf_sync. Upsets are injected by forcing the first synchronizer
-- register of the individual chains through VHDL-2008 external names.

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
entity olo_intf_sync_seu_tb is
    generic (
        runner_cfg : string;
        SyncTmr_g  : boolean := true
    );
end entity;

architecture sim of olo_intf_sync_seu_tb is

    -----------------------------------------------------------------------------------------------
    -- Constants
    -----------------------------------------------------------------------------------------------
    constant DataWidth_c : integer := 2;
    constant Chains_c    : integer := choose(SyncTmr_g, 3, 1);

    -----------------------------------------------------------------------------------------------
    -- TB Defnitions
    -----------------------------------------------------------------------------------------------
    constant Clk_Frequency_c : real := 100.0e6;
    constant Clk_Period_c    : time := (1 sec) / Clk_Frequency_c;

    -----------------------------------------------------------------------------------------------
    -- Interface Signals
    -----------------------------------------------------------------------------------------------
    signal Clk       : std_logic                                  := '0';
    signal Rst       : std_logic                                  := '1';
    signal DataAsync : std_logic_vector(DataWidth_c - 1 downto 0) := (others => '0');
    signal DataSync  : std_logic_vector(DataWidth_c - 1 downto 0);

    -----------------------------------------------------------------------------------------------
    -- TB Signals
    -----------------------------------------------------------------------------------------------
    signal OutChanges  : natural                  := 0;
    signal UpsetReq    : natural                  := 0;
    signal UpsetChains : std_logic_vector(0 to 2) := "000";
    signal SkewReq     : natural                  := 0;

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

    -- Upset of the first synchronizer register in the selected chains for one clock cycle
    procedure upset (
        Chains             : std_logic_vector(0 to 2);
        signal UpsetChains : out std_logic_vector(0 to 2);
        signal UpsetReq    : inout natural) is
    begin
        UpsetChains <= Chains;
        UpsetReq    <= UpsetReq + 1;
        wait for 10 * Clk_Period_c;
    end procedure;

begin

    -----------------------------------------------------------------------------------------------
    -- DUT
    -----------------------------------------------------------------------------------------------
    i_dut : entity olo.olo_intf_sync
        generic map (
            Width_g   => DataWidth_c,
            SyncTmr_g => SyncTmr_g
        )
        port map (
            Clk       => Clk,
            Rst       => Rst,
            DataAsync => DataAsync,
            DataSync  => DataSync
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
        variable Changes_v : natural;
    begin
        test_runner_setup(runner, runner_cfg);

        while test_suite loop

            -- Reset
            DataAsync <= (others => '0');
            Rst       <= '1';
            wait for 2 * Clk_Period_c;
            Rst       <= '0';
            wait for 10 * Clk_Period_c;

            -- Single upsets in every chain while the input is stable
            if run("Seu-Single") then
                DataAsync <= "01";
                wait for 10 * Clk_Period_c;
                Changes_v := OutChanges;

                for c in 0 to Chains_c - 1 loop
                    upset(oneChain(c), UpsetChains, UpsetReq);
                end loop;

                if SyncTmr_g then
                    check_equal(OutChanges, Changes_v, "Single upset visible on the output");
                else
                    -- Without triplication, the upset is visible (validates the injection)
                    check_equal(OutChanges, Changes_v + 2, "Single upset not visible without triplication");
                end if;
                check_equal(DataSync, std_logic_vector'("01"), "Wrong output after upsets");

            -- Two upsets at the same time are visible (validates the injection into every chain)
            elsif run("Seu-Double") then
                if SyncTmr_g then
                    DataAsync <= "10";
                    wait for 10 * Clk_Period_c;
                    Changes_v := OutChanges;
                    upset("110", UpsetChains, UpsetReq);
                    upset("011", UpsetChains, UpsetReq);
                    upset("101", UpsetChains, UpsetReq);
                    check_equal(OutChanges, Changes_v + 6, "Double upset not visible on the output");
                    check_equal(DataSync, std_logic_vector'("10"), "Wrong output after upsets");
                end if;

            -- Levels of two clock cycles: one chain sees the change one cycle late (skew) and a second chain is upset
            -- back to the old value in the same cycle. Every change must still appear exactly once.
            elsif run("Seu-SkewAndUpset") then
                if SyncTmr_g then
                    wait until rising_edge(Clk);
                    Changes_v := OutChanges;

                    for i in 0 to 19 loop
                        wait for 0.3 * Clk_Period_c;
                        DataAsync(0) <= not DataAsync(0);
                        SkewReq      <= SkewReq + 1;
                        wait until rising_edge(Clk);
                        wait until rising_edge(Clk);
                    end loop;

                    wait for 10 * Clk_Period_c;
                    check_equal(OutChanges, Changes_v + 20, "Changes lost or added");
                    check_equal(DataSync, DataAsync, "Wrong output after the last change");
                end if;
            end if;

        end loop;

        -- TB done
        test_runner_cleanup(runner);
    end process;

    -----------------------------------------------------------------------------------------------
    -- Output change counter
    -----------------------------------------------------------------------------------------------
    p_count : process (Clk) is
        variable Last_v : std_logic_vector(DataWidth_c - 1 downto 0) := (others => '0');
    begin
        if rising_edge(Clk) then
            if DataSync /= Last_v then
                OutChanges <= OutChanges + 1;
            end if;
            Last_v := DataSync;
        end if;
    end process;

    -----------------------------------------------------------------------------------------------
    -- Upset injection, chain 0
    -----------------------------------------------------------------------------------------------
    p_upset_chain0 : process is
        alias Reg0 is << signal .olo_intf_sync_seu_tb.i_dut.Reg0 : std_logic_vector(DataWidth_c - 1 downto 0) >>;
    begin
        wait on UpsetReq;
        if UpsetChains(0) = '1' then
            wait until rising_edge(Clk);
            wait for 1 ps;
            Reg0 <= force not Reg0;
            wait until rising_edge(Clk);
            Reg0 <= release;
        end if;
    end process;

    -----------------------------------------------------------------------------------------------
    -- Upset injection, chains 1 and 2
    -----------------------------------------------------------------------------------------------
    g_tmr : if SyncTmr_g generate

        g_chain : for c in 1 to 2 generate

            p_upset : process is
                alias Reg0 is << signal .olo_intf_sync_seu_tb.i_dut.g_tmr.g_chain(c).Reg0 :
                    std_logic_vector(DataWidth_c - 1 downto 0) >>;
            begin
                wait on UpsetReq;
                if UpsetChains(c) = '1' then
                    wait until rising_edge(Clk);
                    wait for 1 ps;
                    Reg0 <= force not Reg0;
                    wait until rising_edge(Clk);
                    Reg0 <= release;
                end if;
            end process;

        end generate;

        -- Worst case after a change of the input: chain 2 takes the new value one clock cycle late (skew between
        -- the chains) and chain 0 is upset back to the old value in the same cycle. Reg0 of both chains keeps the
        -- old value until the second clock edge after the change has been sampled.
        p_skew : process is
            alias Reg00 is << signal .olo_intf_sync_seu_tb.i_dut.Reg0 : std_logic_vector(DataWidth_c - 1 downto 0) >>;
            alias Reg02 is << signal .olo_intf_sync_seu_tb.i_dut.g_tmr.g_chain(2).Reg0 :
                std_logic_vector(DataWidth_c - 1 downto 0) >>;
        begin
            wait on SkewReq;
            -- SkewReq is set together with the change of the input
            Reg00 <= force (DataAsync(1) & not DataAsync(0));
            Reg02 <= force (DataAsync(1) & not DataAsync(0));
            wait until rising_edge(Clk);
            wait until rising_edge(Clk);
            Reg00 <= release;
            Reg02 <= release;
        end process;

    end generate;

end architecture;
