---------------------------------------------------------------------------------------------------
-- Copyright (c) 2026 by Julian Schneider
-- Authors: Julian Schneider
---------------------------------------------------------------------------------------------------

---------------------------------------------------------------------------------------------------
-- Description
---------------------------------------------------------------------------------------------------
-- Single-event upset tests for olo_base_cc_reset. Upsets are injected by forcing the first stage of
-- the reset request synchronizer chains through VHDL-2008 external names.

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
entity olo_base_cc_reset_seu_tb is
    generic (
        runner_cfg     : string;
        ClockRatio_N_g : integer := 3;
        ClockRatio_D_g : integer := 2;
        SyncTmr_g      : boolean := true
    );
end entity;

architecture sim of olo_base_cc_reset_seu_tb is

    -----------------------------------------------------------------------------------------------
    -- Constants
    -----------------------------------------------------------------------------------------------
    constant ClockRatio_c : real    := real(ClockRatio_N_g) / real(ClockRatio_D_g);
    constant Chains_c     : integer := choose(SyncTmr_g, 3, 1);

    -----------------------------------------------------------------------------------------------
    -- TB Defnitions
    -----------------------------------------------------------------------------------------------
    constant ClkA_Frequency_c     : real := 100.0e6;
    constant ClkA_Period_c        : time := (1 sec) / ClkA_Frequency_c;
    constant ClkB_Frequency_c     : real := ClkA_Frequency_c * ClockRatio_c;
    constant ClkB_Period_c        : time := (1 sec) / ClkB_Frequency_c;
    constant SlowerClock_Period_c : time := (1 sec) / minimum(ClkA_Frequency_c, ClkB_Frequency_c);

    -- Upset injection
    type Direction_t is (DirB2A, DirA2B);

    -----------------------------------------------------------------------------------------------
    -- Interface Signals
    -----------------------------------------------------------------------------------------------
    signal A_Clk    : std_logic := '0';
    signal A_RstIn  : std_logic := '0';
    signal A_RstOut : std_logic;
    signal B_Clk    : std_logic := '0';
    signal B_RstIn  : std_logic := '0';
    signal B_RstOut : std_logic;

    -----------------------------------------------------------------------------------------------
    -- TB Signals
    -----------------------------------------------------------------------------------------------
    signal ARstPulses  : natural                  := 0;
    signal BRstPulses  : natural                  := 0;
    signal UpsetReq    : natural                  := 0;
    signal UpsetChains : std_logic_vector(0 to 2) := "000";
    signal UpsetDir    : Direction_t              := DirB2A;

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

    -- Upset of the first stage of the request synchronizer in the selected chains for one clock cycle
    procedure upset (
        Chains             : std_logic_vector(0 to 2);
        Dir                : Direction_t;
        signal UpsetChains : out std_logic_vector(0 to 2);
        signal UpsetDir    : out Direction_t;
        signal UpsetReq    : inout natural) is
    begin
        UpsetChains <= Chains;
        UpsetDir    <= Dir;
        UpsetReq    <= UpsetReq + 1;
        wait for 20 * SlowerClock_Period_c;
    end procedure;

begin

    -----------------------------------------------------------------------------------------------
    -- DUT
    -----------------------------------------------------------------------------------------------
    i_dut : entity olo.olo_base_cc_reset
        generic map (
            SyncTmr_g => SyncTmr_g
        )
        port map (
            A_Clk    => A_Clk,
            A_RstIn  => A_RstIn,
            A_RstOut => A_RstOut,
            B_Clk    => B_Clk,
            B_RstIn  => B_RstIn,
            B_RstOut => B_RstOut
        );

    -----------------------------------------------------------------------------------------------
    -- Clock
    -----------------------------------------------------------------------------------------------
    A_Clk <= not A_Clk after 0.5 * ClkA_Period_c;
    B_Clk <= not B_Clk after 0.5 * ClkB_Period_c;

    -----------------------------------------------------------------------------------------------
    -- TB Control
    -----------------------------------------------------------------------------------------------
    test_runner_watchdog(runner, 1 ms);

    p_control : process is
        variable APulses_v : natural;
        variable BPulses_v : natural;
    begin
        test_runner_setup(runner, runner_cfg);

        while test_suite loop

            -- Reset
            wait until rising_edge(A_Clk);
            A_RstIn   <= '1';
            wait until rising_edge(A_Clk);
            A_RstIn   <= '0';
            wait for 20 * SlowerClock_Period_c;
            check_equal(A_RstOut, '0', "A_RstOut not released");
            check_equal(B_RstOut, '0', "B_RstOut not released");
            APulses_v := ARstPulses;
            BPulses_v := BRstPulses;

            -- Single upsets in every chain of both directions
            if run("Seu-Single") then

                for c in 0 to Chains_c - 1 loop
                    upset(oneChain(c), DirB2A, UpsetChains, UpsetDir, UpsetReq);
                    upset(oneChain(c), DirA2B, UpsetChains, UpsetDir, UpsetReq);
                end loop;

                if SyncTmr_g then
                    check_equal(ARstPulses, APulses_v, "Spurious reset on A_RstOut");
                    check_equal(BRstPulses, BPulses_v, "Spurious reset on B_RstOut");
                else
                    -- Without triplication, the upset is visible (validates the injection)
                    check_equal(ARstPulses, APulses_v + 1, "Upset not visible on A_RstOut without triplication");
                    check_equal(BRstPulses, BPulses_v + 1, "Upset not visible on B_RstOut without triplication");
                end if;

            -- Two upsets at the same time are visible (validates the injection into every chain)
            elsif run("Seu-Double") then
                if SyncTmr_g then
                    upset("110", DirB2A, UpsetChains, UpsetDir, UpsetReq);
                    upset("011", DirB2A, UpsetChains, UpsetDir, UpsetReq);
                    upset("101", DirB2A, UpsetChains, UpsetDir, UpsetReq);
                    check_equal(ARstPulses, APulses_v + 3, "Double upset not visible on A_RstOut");
                    upset("110", DirA2B, UpsetChains, UpsetDir, UpsetReq);
                    upset("011", DirA2B, UpsetChains, UpsetDir, UpsetReq);
                    upset("101", DirA2B, UpsetChains, UpsetDir, UpsetReq);
                    check_equal(BRstPulses, BPulses_v + 3, "Double upset not visible on B_RstOut");
                end if;
            end if;

        end loop;

        -- TB done
        test_runner_cleanup(runner);
    end process;

    -----------------------------------------------------------------------------------------------
    -- Reset pulse counters
    -----------------------------------------------------------------------------------------------
    p_count_a : process (A_RstOut) is
    begin
        if rising_edge(A_RstOut) then
            ARstPulses <= ARstPulses + 1;
        end if;
    end process;

    p_count_b : process (B_RstOut) is
    begin
        if rising_edge(B_RstOut) then
            BRstPulses <= BRstPulses + 1;
        end if;
    end process;

    -----------------------------------------------------------------------------------------------
    -- Upset injection, chain 0
    -----------------------------------------------------------------------------------------------
    p_upset_chain0 : process is
        alias RstRqstB2A is << signal .olo_base_cc_reset_seu_tb.i_dut.RstRqstB2A : std_logic_vector(2 downto 0) >>;
        alias RstRqstA2B is << signal .olo_base_cc_reset_seu_tb.i_dut.RstRqstA2B : std_logic_vector(2 downto 0) >>;
    begin
        wait on UpsetReq;
        if UpsetChains(0) = '1' then
            if UpsetDir = DirB2A then
                wait until rising_edge(A_Clk);
                wait for 1 ps;
                RstRqstB2A <= force RstRqstB2A(2 downto 1) & not RstRqstB2A(0);
                wait until rising_edge(A_Clk);
                RstRqstB2A <= release;
            else
                wait until rising_edge(B_Clk);
                wait for 1 ps;
                RstRqstA2B <= force RstRqstA2B(2 downto 1) & not RstRqstA2B(0);
                wait until rising_edge(B_Clk);
                RstRqstA2B <= release;
            end if;
        end if;
    end process;

    -----------------------------------------------------------------------------------------------
    -- Upset injection, chains 1 and 2
    -----------------------------------------------------------------------------------------------
    g_tmr : if SyncTmr_g generate

        g_chain : for c in 1 to 2 generate

            p_upset : process is
                alias RstRqstB2A is << signal .olo_base_cc_reset_seu_tb.i_dut.g_tmr.g_chain(c).RstRqstB2A :
                    std_logic_vector(2 downto 0) >>;
                alias RstRqstA2B is << signal .olo_base_cc_reset_seu_tb.i_dut.g_tmr.g_chain(c).RstRqstA2B :
                    std_logic_vector(2 downto 0) >>;
            begin
                wait on UpsetReq;
                if UpsetChains(c) = '1' then
                    if UpsetDir = DirB2A then
                        wait until rising_edge(A_Clk);
                        wait for 1 ps;
                        RstRqstB2A <= force RstRqstB2A(2 downto 1) & not RstRqstB2A(0);
                        wait until rising_edge(A_Clk);
                        RstRqstB2A <= release;
                    else
                        wait until rising_edge(B_Clk);
                        wait for 1 ps;
                        RstRqstA2B <= force RstRqstA2B(2 downto 1) & not RstRqstA2B(0);
                        wait until rising_edge(B_Clk);
                        RstRqstA2B <= release;
                    end if;
                end if;
            end process;

        end generate;

    end generate;

end architecture;
