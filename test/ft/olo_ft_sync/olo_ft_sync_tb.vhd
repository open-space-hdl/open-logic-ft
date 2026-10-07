---------------------------------------------------------------------------------------------------
-- Copyright (c) 2026 by Julian Schneider
-- Authors: Julian Schneider
---------------------------------------------------------------------------------------------------

---------------------------------------------------------------------------------------------------
-- Libraries
---------------------------------------------------------------------------------------------------
library ieee;
    use ieee.std_logic_1164.all;
    use ieee.numeric_std.all;
    use ieee.math_real.all;

library vunit_lib;
    context vunit_lib.vunit_context;

library work;
    use work.olo_test_activity_pkg.all;

library olo;
    use olo.olo_base_pkg_math.all;

---------------------------------------------------------------------------------------------------
-- Entity
---------------------------------------------------------------------------------------------------
-- vunit: run_all_in_same_sim
entity olo_ft_sync_tb is
    generic (
        RstLevel_g     : natural range 0 to 1  := 0;
        SyncStages_g   : positive range 2 to 4 := 2;
        runner_cfg     : string
    );
end entity;

architecture sim of olo_ft_sync_tb is

    -----------------------------------------------------------------------------------------------
    -- Constants
    -----------------------------------------------------------------------------------------------
    constant DataWidth_c : integer   := 8;
    constant RstLevel_c  : std_logic := toStdl(RstLevel_g);

    -----------------------------------------------------------------------------------------------
    -- TB Defnitions
    -----------------------------------------------------------------------------------------------
    constant Clk_Frequency_c : real := 100.0e6;
    constant Clk_Period_c    : time := (1 sec) / Clk_Frequency_c;
    constant Time_MaxDel_c   : time := (real(SyncStages_g) + 0.1)* Clk_Period_c; -- 1 cycle per stage

    -----------------------------------------------------------------------------------------------
    -- Interface Signals
    -----------------------------------------------------------------------------------------------
    signal Clk       : std_logic                                  := '0';
    signal Rst       : std_logic                                  := '1';
    signal DataAsync : std_logic_vector(DataWidth_c - 1 downto 0) := (others => RstLevel_c);
    signal DataSync  : std_logic_vector(DataWidth_c - 1 downto 0);

begin

    -----------------------------------------------------------------------------------------------
    -- DUT
    -----------------------------------------------------------------------------------------------
    i_dut : entity olo.olo_ft_sync
        generic map (
            Width_g      => DataWidth_c,
            RstLevel_g   => RstLevel_c,
            SyncStages_g => SyncStages_g
        )
        port map (
            Clk         => Clk,
            Rst         => Rst,
            DataAsync   => DataAsync,
            DataSync    => DataSync
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
        constant RstVal_c : std_logic_vector(DataWidth_c - 1 downto 0) := (others => RstLevel_c);

        -- First synchronizer stage of the TMR copies inside the DUT
        alias Reg0A is << signal .olo_ft_sync_tb.i_dut.g_copy(0).Reg0 : std_logic_vector(DataWidth_c - 1 downto 0) >>;
        alias Reg0B is << signal .olo_ft_sync_tb.i_dut.g_copy(1).Reg0 : std_logic_vector(DataWidth_c - 1 downto 0) >>;
        alias Reg0C is << signal .olo_ft_sync_tb.i_dut.g_copy(2).Reg0 : std_logic_vector(DataWidth_c - 1 downto 0) >>;

        -- Upset all bits of the first stage of the selected copies for one clock edge
        procedure flip (
            Copies : std_logic_vector(0 to 2)) is
        begin
            wait until rising_edge(Clk);
            wait for 0.25 * Clk_Period_c;
            if Copies(0) = '1' then
                Reg0A <= force not Reg0A;
            end if;
            if Copies(1) = '1' then
                Reg0B <= force not Reg0B;
            end if;
            if Copies(2) = '1' then
                Reg0C <= force not Reg0C;
            end if;
            wait until rising_edge(Clk);
            wait for 0.25 * Clk_Period_c;
            Reg0A <= release;
            Reg0B <= release;
            Reg0C <= release;
        end procedure;

        variable Start_v : time;
    begin
        test_runner_setup(runner, runner_cfg);

        while test_suite loop

            -- *** Reset ***
            Rst <= '1';
            wait until rising_edge(Clk);
            Rst <= '0';
            wait until rising_edge(Clk);

            if run("ResetValue") then
                check_equal(DataSync, RstVal_c, "Data not reset");
            end if;

            if run("SimpleTransfer") then
                DataAsync <= x"AB";
                wait_for_value_stdlv(DataSync, x"AB", Time_MaxDel_c, "Data not transferred 1");
                DataAsync <= x"CD";
                wait_for_value_stdlv(DataSync, x"CD", Time_MaxDel_c, "Data not transferred 2");
            end if;

            -- Upsets of a single copy do not change the output (one copy at a time, each upset
            -- shifted out of the chain before the next one)
            if run("Seu-Single") then
                DataAsync <= x"5A";
                wait_for_value_stdlv(DataSync, x"5A", Time_MaxDel_c, "Data not transferred");
                wait until rising_edge(Clk);
                Start_v   := now;
                flip("100");
                wait for Clk_Period_c * (SyncStages_g + 2);
                flip("010");
                wait for Clk_Period_c * (SyncStages_g + 2);
                flip("001");
                wait for Clk_Period_c * (SyncStages_g + 2);
                check(DataSync'last_event >= now - Start_v, "Output changed by a single upset");
                check_equal(DataSync, std_logic_vector'(x"5A"), "Output changed by a single upset");
            end if;

            -- Sanity check of the injection: upsets of two copies are not masked
            if run("DoubleFault-Visible") then
                DataAsync <= x"5A";
                wait_for_value_stdlv(DataSync, x"5A", Time_MaxDel_c, "Data not transferred");
                flip("110");
                wait_for_value_stdlv(DataSync, x"A5", Time_MaxDel_c, "Double upset not visible");
                wait_for_value_stdlv(DataSync, x"5A", Time_MaxDel_c, "Upset not shifted out");
            end if;

        end loop;

        -- TB done
        test_runner_cleanup(runner);
    end process;

end architecture;
