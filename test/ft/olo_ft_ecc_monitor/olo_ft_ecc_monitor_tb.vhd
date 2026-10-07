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

library vunit_lib;
    context vunit_lib.vunit_context;

library olo;
    use olo.olo_base_pkg_math.all;

---------------------------------------------------------------------------------------------------
-- Entity
---------------------------------------------------------------------------------------------------
-- vunit: run_all_in_same_sim
entity olo_ft_ecc_monitor_tb is
    generic (
        runner_cfg     : string;
        Channels_g     : positive range 1 to 255 := 4;
        CounterWidth_g : positive range 1 to 16  := 16
    );
end entity;

---------------------------------------------------------------------------------------------------
-- Architecture
---------------------------------------------------------------------------------------------------
architecture sim of olo_ft_ecc_monitor_tb is

    -----------------------------------------------------------------------------------------------
    -- Constants
    -----------------------------------------------------------------------------------------------
    constant ClkPeriod_c   : time     := 10 ns;
    constant ChannelBits_c : positive := max(log2ceil(Channels_g), 1);
    constant CounterMax_c  : natural  := 2**CounterWidth_g - 1;
    -- Second test channel, folded back to 0 for the single-channel configuration
    constant ChB_c         : natural := minimum(1, Channels_g - 1);

    -----------------------------------------------------------------------------------------------
    -- TB Procedures
    -----------------------------------------------------------------------------------------------
    -- Pulse SEC/DED flags on one channel for a single clock cycle
    procedure pulseEvent (
        channel        : in natural;
        sec            : in std_logic;
        ded            : in std_logic;
        signal Clk     : in std_logic;
        signal SecFlag : out std_logic_vector;
        signal DedFlag : out std_logic_vector) is
    begin
        wait until rising_edge(Clk);
        SecFlag(channel) <= sec;
        DedFlag(channel) <= ded;
        wait until rising_edge(Clk);
        SecFlag(channel) <= '0';
        DedFlag(channel) <= '0';
    end procedure;

    -- Read one channel and check the returned counter values
    procedure expectRead (
        channel          : in natural;
        sec              : in natural;
        ded              : in natural;
        msg              : in string;
        clr              : in std_logic;
        signal Clk       : in std_logic;
        signal RdChannel : out std_logic_vector;
        signal RdEna     : out std_logic;
        signal RdClr     : out std_logic;
        signal RdValid   : in std_logic;
        signal RdSecCnt  : in std_logic_vector;
        signal RdDedCnt  : in std_logic_vector) is
    begin
        wait until rising_edge(Clk);
        RdChannel <= toUslv(channel, RdChannel'length);
        RdEna     <= '1';
        RdClr     <= clr;
        wait until rising_edge(Clk);
        RdEna     <= '0';
        RdClr     <= '0';
        wait until rising_edge(Clk);
        check_equal(RdValid, '1', "Rd_Valid - " & msg);
        check_equal(RdSecCnt, toUslv(sec, RdSecCnt'length), "Rd_SecCnt - " & msg);
        check_equal(RdDedCnt, toUslv(ded, RdDedCnt'length), "Rd_DedCnt - " & msg);
        wait until rising_edge(Clk);
        check_equal(RdValid, '0', "Rd_Valid not a pulse - " & msg);
    end procedure;

    -----------------------------------------------------------------------------------------------
    -- Interface Signals
    -----------------------------------------------------------------------------------------------
    signal Clk        : std_logic                                    := '0';
    signal Rst        : std_logic                                    := '1';
    signal Clr        : std_logic                                    := '0';
    signal In_EccSec  : std_logic_vector(Channels_g - 1 downto 0)    := (others => '0');
    signal In_EccDed  : std_logic_vector(Channels_g - 1 downto 0)    := (others => '0');
    signal In_Valid   : std_logic_vector(Channels_g - 1 downto 0)    := (others => '1');
    signal DedSticky  : std_logic_vector(Channels_g - 1 downto 0);
    signal Evt_Sec    : std_logic;
    signal Evt_Ded    : std_logic;
    signal Rd_Channel : std_logic_vector(ChannelBits_c - 1 downto 0) := (others => '0');
    signal Rd_Ena     : std_logic                                    := '0';
    signal Rd_Clr     : std_logic                                    := '0';
    signal Rd_SecCnt  : std_logic_vector(CounterWidth_g - 1 downto 0);
    signal Rd_DedCnt  : std_logic_vector(CounterWidth_g - 1 downto 0);
    signal Rd_Valid   : std_logic;

begin

    -----------------------------------------------------------------------------------------------
    -- Clock
    -----------------------------------------------------------------------------------------------
    Clk <= not Clk after 0.5 * ClkPeriod_c;

    -----------------------------------------------------------------------------------------------
    -- DUT
    -----------------------------------------------------------------------------------------------
    i_dut : entity olo.olo_ft_ecc_monitor
        generic map (
            Channels_g     => Channels_g,
            CounterWidth_g => CounterWidth_g
        )
        port map (
            Clk        => Clk,
            Rst        => Rst,
            Clr        => Clr,
            In_EccSec  => In_EccSec,
            In_EccDed  => In_EccDed,
            In_Valid   => In_Valid,
            DedSticky  => DedSticky,
            Evt_Sec    => Evt_Sec,
            Evt_Ded    => Evt_Ded,
            Rd_Channel => Rd_Channel,
            Rd_Ena     => Rd_Ena,
            Rd_Clr     => Rd_Clr,
            Rd_SecCnt  => Rd_SecCnt,
            Rd_DedCnt  => Rd_DedCnt,
            Rd_Valid   => Rd_Valid
        );

    -----------------------------------------------------------------------------------------------
    -- TB Control
    -----------------------------------------------------------------------------------------------
    test_runner_watchdog(runner, 50 ms);

    p_control : process is
        variable SatEvents_v : natural;
        variable ExpCnt_v    : natural;
    begin
        test_runner_setup(runner, runner_cfg);

        while test_suite loop
            -- Reset between cases
            wait until rising_edge(Clk);
            Rst <= '1';
            wait for 200 ns;
            wait until rising_edge(Clk);
            Rst <= '0';
            wait until rising_edge(Clk);

            if run("Basic") then
                pulseEvent(0, '1', '0', Clk, In_EccSec, In_EccDed);
                expectRead(0, 1, 0, "sec counted", '0', Clk, Rd_Channel, Rd_Ena, Rd_Clr, Rd_Valid, Rd_SecCnt, Rd_DedCnt);
                pulseEvent(ChB_c, '0', '1', Clk, In_EccSec, In_EccDed);
                if ChB_c = 0 then
                    -- Single channel: both events land on channel 0
                    expectRead(0, 1, 1, "ded counted", '0', Clk, Rd_Channel, Rd_Ena, Rd_Clr, Rd_Valid, Rd_SecCnt, Rd_DedCnt);
                else
                    expectRead(ChB_c, 0, 1, "ded counted", '0', Clk, Rd_Channel, Rd_Ena, Rd_Clr, Rd_Valid, Rd_SecCnt, Rd_DedCnt);
                    expectRead(0, 1, 0, "sec kept", '0', Clk, Rd_Channel, Rd_Ena, Rd_Clr, Rd_Valid, Rd_SecCnt, Rd_DedCnt);
                    check_equal(DedSticky(0), '0', "DedSticky others clear");
                end if;
                check_equal(DedSticky(ChB_c), '1', "DedSticky set");

            elsif run("ValidGating") then
                wait until rising_edge(Clk);
                In_Valid <= (others => '0');
                pulseEvent(0, '1', '1', Clk, In_EccSec, In_EccDed);
                wait until rising_edge(Clk);
                In_Valid <= (others => '1');
                expectRead(0, 0, 0, "gated event not counted", '0', Clk, Rd_Channel, Rd_Ena, Rd_Clr, Rd_Valid, Rd_SecCnt, Rd_DedCnt);
                check_equal(DedSticky(0), '0', "gated event no sticky");

            elsif run("SimultaneousChannels") then
                wait until rising_edge(Clk);
                In_EccSec <= (others => '1');
                In_EccDed <= (others => '1');
                wait until rising_edge(Clk);
                In_EccSec <= (others => '0');
                In_EccDed <= (others => '0');

                for i in 0 to Channels_g - 1 loop
                    expectRead(i, 1, 1, "channel " & integer'image(i), '0', Clk, Rd_Channel, Rd_Ena, Rd_Clr, Rd_Valid, Rd_SecCnt, Rd_DedCnt);
                    check_equal(DedSticky(i), '1', "sticky " & integer'image(i));
                end loop;

            elsif run("Saturation") then
                -- Full saturation sweep for narrow counters; bounded count check for wide ones
                if CounterWidth_g <= 8 then
                    SatEvents_v := CounterMax_c + 3;
                    ExpCnt_v    := CounterMax_c;
                else
                    SatEvents_v := 5;
                    ExpCnt_v    := 5;
                end if;

                wait until rising_edge(Clk);
                In_EccSec(0) <= '1';
                In_EccDed(0) <= '1';

                for i in 1 to SatEvents_v loop
                    wait until rising_edge(Clk);
                end loop;

                In_EccSec(0) <= '0';
                In_EccDed(0) <= '0';
                expectRead(0, ExpCnt_v, ExpCnt_v, "saturated", '0', Clk, Rd_Channel, Rd_Ena, Rd_Clr, Rd_Valid, Rd_SecCnt, Rd_DedCnt);

            elsif run("GlobalClear") then
                pulseEvent(0, '1', '1', Clk, In_EccSec, In_EccDed);
                pulseEvent(0, '1', '0', Clk, In_EccSec, In_EccDed);
                wait until rising_edge(Clk);
                Clr <= '1';
                wait until rising_edge(Clk);
                Clr <= '0';
                expectRead(0, 0, 0, "cleared", '0', Clk, Rd_Channel, Rd_Ena, Rd_Clr, Rd_Valid, Rd_SecCnt, Rd_DedCnt);
                check_equal(DedSticky(0), '0', "sticky cleared");

            elsif run("ClearWithSimultaneousEvent") then
                pulseEvent(0, '1', '0', Clk, In_EccSec, In_EccDed);
                pulseEvent(0, '1', '0', Clk, In_EccSec, In_EccDed);
                -- Clear and event in the same cycle: the event must survive
                wait until rising_edge(Clk);
                Clr          <= '1';
                In_EccSec(0) <= '1';
                wait until rising_edge(Clk);
                Clr          <= '0';
                In_EccSec(0) <= '0';
                expectRead(0, 1, 0, "event survived the clear", '0', Clk, Rd_Channel, Rd_Ena, Rd_Clr, Rd_Valid, Rd_SecCnt, Rd_DedCnt);

            elsif run("ReadClear") then
                pulseEvent(ChB_c, '1', '1', Clk, In_EccSec, In_EccDed);
                pulseEvent(ChB_c, '1', '0', Clk, In_EccSec, In_EccDed);
                -- Narrow counters saturate below the two counted SEC events
                expectRead(ChB_c, minimum(2, CounterMax_c), 1, "read with clear", '1', Clk, Rd_Channel, Rd_Ena, Rd_Clr, Rd_Valid, Rd_SecCnt, Rd_DedCnt);
                check_equal(DedSticky(ChB_c), '0', "sticky cleared by Rd_Clr");
                expectRead(ChB_c, 0, 0, "cleared after read-clear", '0', Clk, Rd_Channel, Rd_Ena, Rd_Clr, Rd_Valid, Rd_SecCnt, Rd_DedCnt);

            elsif run("ReadClearWithSimultaneousEvent") then
                pulseEvent(ChB_c, '1', '0', Clk, In_EccSec, In_EccDed);
                -- Read-clear and a new event in the same cycle: read returns the pre-clear value,
                -- the event survives the clear
                wait until rising_edge(Clk);
                Rd_Channel       <= toUslv(ChB_c, ChannelBits_c);
                Rd_Ena           <= '1';
                Rd_Clr           <= '1';
                In_EccSec(ChB_c) <= '1';
                wait until rising_edge(Clk);
                Rd_Ena           <= '0';
                Rd_Clr           <= '0';
                In_EccSec(ChB_c) <= '0';
                wait until rising_edge(Clk);
                check_equal(Rd_Valid, '1', "Rd_Valid - simultaneous");
                check_equal(Rd_SecCnt, toUslv(1, CounterWidth_g), "pre-clear value returned");
                expectRead(ChB_c, 1, 0, "event survived the read-clear", '0', Clk, Rd_Channel, Rd_Ena, Rd_Clr, Rd_Valid, Rd_SecCnt, Rd_DedCnt);

            elsif run("StickySemantics") then
                pulseEvent(0, '1', '0', Clk, In_EccSec, In_EccDed);
                check_equal(DedSticky(0), '0', "SEC does not set DedSticky");
                pulseEvent(0, '0', '1', Clk, In_EccSec, In_EccDed);
                wait until rising_edge(Clk);
                check_equal(DedSticky(0), '1', "DED sets DedSticky");
                pulseEvent(0, '0', '1', Clk, In_EccSec, In_EccDed);
                wait until rising_edge(Clk);
                check_equal(DedSticky(0), '1', "DedSticky stays set");

            elsif run("EvtPulses") then
                -- Two isolated events produce two isolated one-cycle pulses
                pulseEvent(0, '1', '0', Clk, In_EccSec, In_EccDed);
                wait until rising_edge(Clk);
                check_equal(Evt_Sec, '1', "Evt_Sec pulse 1");
                check_equal(Evt_Ded, '0', "no Evt_Ded");
                wait until rising_edge(Clk);
                check_equal(Evt_Sec, '0', "Evt_Sec back to zero");
                pulseEvent(0, '0', '1', Clk, In_EccSec, In_EccDed);
                wait until rising_edge(Clk);
                check_equal(Evt_Ded, '1', "Evt_Ded pulse");
                wait until rising_edge(Clk);
                check_equal(Evt_Ded, '0', "Evt_Ded back to zero");

            elsif run("OutOfRangeChannel") then
                -- Only reachable when the channel count is not a power of two
                if 2**ChannelBits_c > Channels_g then
                    pulseEvent(0, '1', '0', Clk, In_EccSec, In_EccDed);
                    wait until rising_edge(Clk);
                    Rd_Channel <= toUslv(2**ChannelBits_c - 1, ChannelBits_c);
                    Rd_Ena     <= '1';
                    wait until rising_edge(Clk);
                    Rd_Ena     <= '0';
                    wait until rising_edge(Clk);
                    check_equal(Rd_Valid, '1', "Rd_Valid - out of range");
                    check_equal(Rd_SecCnt, toUslv(0, CounterWidth_g), "zeros for out-of-range channel");
                    check_equal(Rd_DedCnt, toUslv(0, CounterWidth_g), "zeros for out-of-range channel ded");
                end if;

            elsif run("ResetInFlight") then
                pulseEvent(0, '1', '1', Clk, In_EccSec, In_EccDed);
                -- Issue a read and reset in the same cycle: the response must be squashed
                wait until rising_edge(Clk);
                Rd_Ena <= '1';
                Rst    <= '1';
                wait until rising_edge(Clk);
                Rd_Ena <= '0';
                wait until rising_edge(Clk);
                Rst    <= '0';
                check_equal(Rd_Valid, '0', "no stale Rd_Valid after reset");
                check_equal(DedSticky(0), '0', "sticky cleared by reset");
                wait until rising_edge(Clk);
                expectRead(0, 0, 0, "counters cleared by reset", '0', Clk, Rd_Channel, Rd_Ena, Rd_Clr, Rd_Valid, Rd_SecCnt, Rd_DedCnt);
            end if;

        end loop;

        test_runner_cleanup(runner);
    end process;

end architecture;
