---------------------------------------------------------------------------------------------------
-- Copyright (c) 2026 by Julian Schneider
-- Authors: Julian Schneider
---------------------------------------------------------------------------------------------------

---------------------------------------------------------------------------------------------------
-- Description
---------------------------------------------------------------------------------------------------
-- Single-event upset tests for olo_base_cc_bits. Upsets are injected by forcing the synchronizer
-- registers of the individual chains through VHDL-2008 external names.

---------------------------------------------------------------------------------------------------
-- Libraries
---------------------------------------------------------------------------------------------------
library ieee;
    use ieee.std_logic_1164.all;
    use ieee.numeric_std.all;
    use ieee.math_real.all;

library vunit_lib;
    context vunit_lib.vunit_context;

library olo;
    use olo.olo_base_pkg_math.all;

---------------------------------------------------------------------------------------------------
-- Entity
---------------------------------------------------------------------------------------------------
-- vunit: run_all_in_same_sim
entity olo_base_cc_bits_seu_tb is
    generic (
        runner_cfg     : string;
        ClockRatio_N_g : integer := 3;
        ClockRatio_D_g : integer := 2;
        SyncTmr_g      : boolean := true
    );
end entity;

architecture sim of olo_base_cc_bits_seu_tb is

    -----------------------------------------------------------------------------------------------
    -- Constants
    -----------------------------------------------------------------------------------------------
    constant ClockRatio_c : real    := real(ClockRatio_N_g) / real(ClockRatio_D_g);
    constant DataWidth_c  : integer := 2;
    constant Chains_c     : integer := choose(SyncTmr_g, 3, 1);

    -----------------------------------------------------------------------------------------------
    -- TB Defnitions
    -----------------------------------------------------------------------------------------------
    constant ClkIn_Frequency_c    : real := 100.0e6;
    constant ClkIn_Period_c       : time := (1 sec) / ClkIn_Frequency_c;
    constant ClkOut_Frequency_c   : real := ClkIn_Frequency_c * ClockRatio_c;
    constant ClkOut_Period_c      : time := (1 sec) / ClkOut_Frequency_c;
    constant SlowerClock_Period_c : time := (1 sec) / minimum(ClkIn_Frequency_c, ClkOut_Frequency_c);

    -- Shortest level that is fully protected: two clock cycles of the slower clock (in input clock cycles)
    constant StableCycles_c : positive := integer(ceil(2.0 * real(SlowerClock_Period_c / 1 ps) /
                                                       real(ClkIn_Period_c / 1 ps)));

    -- Upset injection
    type Reg_t is (UpsetRegIn, UpsetReg0);

    -----------------------------------------------------------------------------------------------
    -- Interface Signals
    -----------------------------------------------------------------------------------------------
    signal In_Clk   : std_logic                                  := '0';
    signal In_Rst   : std_logic                                  := '1';
    signal In_Data  : std_logic_vector(DataWidth_c - 1 downto 0) := (others => '0');
    signal Out_Clk  : std_logic                                  := '0';
    signal Out_Rst  : std_logic                                  := '1';
    signal Out_Data : std_logic_vector(DataWidth_c - 1 downto 0);

    -----------------------------------------------------------------------------------------------
    -- TB Signals
    -----------------------------------------------------------------------------------------------
    signal OutChanges  : natural                  := 0;
    signal UpsetReq    : natural                  := 0;
    signal UpsetChains : std_logic_vector(0 to 2) := "000";
    signal UpsetReg    : Reg_t                    := UpsetRegIn;
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

    -- Upset of one register in the selected chains for one clock cycle
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
        wait for 10 * SlowerClock_Period_c;
    end procedure;

begin

    -----------------------------------------------------------------------------------------------
    -- DUT
    -----------------------------------------------------------------------------------------------
    i_dut : entity olo.olo_base_cc_bits
        generic map (
            Width_g   => DataWidth_c,
            SyncTmr_g => SyncTmr_g
        )
        port map (
            In_Clk   => In_Clk,
            In_Rst   => In_Rst,
            In_Data  => In_Data,
            Out_Clk  => Out_Clk,
            Out_Rst  => Out_Rst,
            Out_Data => Out_Data
        );

    -----------------------------------------------------------------------------------------------
    -- Clock
    -----------------------------------------------------------------------------------------------
    In_Clk  <= not In_Clk after 0.5 * ClkIn_Period_c;
    Out_Clk <= not Out_Clk after 0.5 * ClkOut_Period_c;

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
            In_Data <= (others => '0');
            In_Rst  <= '1';
            Out_Rst <= '1';
            wait for 2 * SlowerClock_Period_c;
            In_Rst  <= '0';
            Out_Rst <= '0';
            wait for 10 * SlowerClock_Period_c;

            -- Single upsets in every chain and register while the input is stable
            if run("Seu-Single") then
                wait until rising_edge(In_Clk);
                In_Data   <= "01";
                wait for 10 * SlowerClock_Period_c;
                Changes_v := OutChanges;

                for c in 0 to Chains_c - 1 loop

                    for r in Reg_t loop
                        upset(oneChain(c), r, UpsetChains, UpsetReg, UpsetReq);
                    end loop;

                end loop;

                if SyncTmr_g then
                    check_equal(OutChanges, Changes_v, "Single upset visible on the output");
                else
                    -- Without triplication, the upset of Reg0 is visible (validates the injection)
                    check(OutChanges >= Changes_v + 2, "Single upset not visible without triplication");
                end if;
                check_equal(Out_Data, std_logic_vector'("01"), "Wrong output after upsets");

            -- Two upsets at the same time are visible (validates the injection into every chain)
            elsif run("Seu-Double") then
                if SyncTmr_g then
                    wait until rising_edge(In_Clk);
                    In_Data   <= "10";
                    wait for 10 * SlowerClock_Period_c;
                    Changes_v := OutChanges;
                    upset("110", UpsetReg0, UpsetChains, UpsetReg, UpsetReq);
                    upset("011", UpsetReg0, UpsetChains, UpsetReg, UpsetReq);
                    upset("101", UpsetReg0, UpsetChains, UpsetReg, UpsetReq);
                    check_equal(OutChanges, Changes_v + 6, "Double upset not visible on the output");
                    check_equal(Out_Data, std_logic_vector'("10"), "Wrong output after upsets");
                end if;

            -- Levels of two slower clock cycles: one chain sees the change one cycle late (skew) and a second chain
            -- is upset back to the old value in the same cycle. Every change must still appear exactly once.
            elsif run("Seu-SkewAndUpset") then
                if SyncTmr_g then
                    wait until rising_edge(In_Clk);
                    Changes_v := OutChanges;

                    for i in 0 to 19 loop
                        In_Data(0) <= not In_Data(0);
                        wait until rising_edge(In_Clk);
                        SkewReq    <= SkewReq + 1;

                        for j in 1 to StableCycles_c - 1 loop
                            wait until rising_edge(In_Clk);
                        end loop;

                    end loop;

                    wait for 10 * SlowerClock_Period_c;
                    check_equal(OutChanges, Changes_v + 20, "Changes lost or added");
                    check_equal(Out_Data, In_Data, "Wrong output after the last change");
                end if;
            end if;

        end loop;

        -- TB done
        test_runner_cleanup(runner);
    end process;

    -----------------------------------------------------------------------------------------------
    -- Output change counter
    -----------------------------------------------------------------------------------------------
    p_count : process (Out_Clk) is
        variable Last_v : std_logic_vector(DataWidth_c - 1 downto 0) := (others => '0');
    begin
        if rising_edge(Out_Clk) then
            if Out_Data /= Last_v then
                OutChanges <= OutChanges + 1;
            end if;
            Last_v := Out_Data;
        end if;
    end process;

    -----------------------------------------------------------------------------------------------
    -- Upset injection, chain 0
    -----------------------------------------------------------------------------------------------
    p_upset_chain0 : process is
        alias RegIn is << signal .olo_base_cc_bits_seu_tb.i_dut.RegIn : std_logic_vector(DataWidth_c - 1 downto 0) >>;
        alias Reg0  is << signal .olo_base_cc_bits_seu_tb.i_dut.Reg0 : std_logic_vector(DataWidth_c - 1 downto 0) >>;
    begin
        wait on UpsetReq;
        if UpsetChains(0) = '1' then
            if UpsetReg = UpsetRegIn then
                wait until rising_edge(In_Clk);
                wait for 1 ps;
                RegIn <= force not RegIn;
                wait until rising_edge(In_Clk);
                RegIn <= release;
            else
                wait until rising_edge(Out_Clk);
                wait for 1 ps;
                Reg0 <= force not Reg0;
                wait until rising_edge(Out_Clk);
                Reg0 <= release;
            end if;
        end if;
    end process;

    -----------------------------------------------------------------------------------------------
    -- Upset injection, chains 1 and 2
    -----------------------------------------------------------------------------------------------
    g_tmr : if SyncTmr_g generate

        g_chain : for c in 1 to 2 generate

            p_upset : process is
                alias RegIn is << signal .olo_base_cc_bits_seu_tb.i_dut.g_tmr.g_chain(c).RegIn :
                    std_logic_vector(DataWidth_c - 1 downto 0) >>;
                alias Reg0  is << signal .olo_base_cc_bits_seu_tb.i_dut.g_tmr.g_chain(c).Reg0 :
                    std_logic_vector(DataWidth_c - 1 downto 0) >>;
            begin
                wait on UpsetReq;
                if UpsetChains(c) = '1' then
                    if UpsetReg = UpsetRegIn then
                        wait until rising_edge(In_Clk);
                        wait for 1 ps;
                        RegIn <= force not RegIn;
                        wait until rising_edge(In_Clk);
                        RegIn <= release;
                    else
                        wait until rising_edge(Out_Clk);
                        wait for 1 ps;
                        Reg0 <= force not Reg0;
                        wait until rising_edge(Out_Clk);
                        Reg0 <= release;
                    end if;
                end if;
            end process;

        end generate;

        -- Worst case after a change of the input: chain 2 takes the new value one clock cycle late (skew between
        -- the chains) and chain 0 is upset back to the old value in the same cycle. Reg0 of both chains keeps the
        -- old value until the second Out_Clk edge after the change has been sampled.
        p_skew : process is
            alias RegIn0 is << signal .olo_base_cc_bits_seu_tb.i_dut.RegIn : std_logic_vector(DataWidth_c - 1 downto 0) >>;
            alias Reg00  is << signal .olo_base_cc_bits_seu_tb.i_dut.Reg0 : std_logic_vector(DataWidth_c - 1 downto 0) >>;
            alias Reg02  is << signal .olo_base_cc_bits_seu_tb.i_dut.g_tmr.g_chain(2).Reg0 :
                std_logic_vector(DataWidth_c - 1 downto 0) >>;
        begin
            wait on SkewReq;
            -- SkewReq is set in the cycle in which RegIn takes the new value
            wait for 1 ps;
            Reg00 <= force (RegIn0(1) & not RegIn0(0));
            Reg02 <= force (RegIn0(1) & not RegIn0(0));
            wait until rising_edge(Out_Clk);
            wait until rising_edge(Out_Clk);
            Reg00 <= release;
            Reg02 <= release;
        end process;

    end generate;

end architecture;
