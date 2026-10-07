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
    context vunit_lib.com_context;
    context vunit_lib.vc_context;

library olo;
    use olo.olo_base_pkg_math.all;

library work;
    use work.olo_test_pkg_axi.all;
    use work.olo_test_axi_master_pkg.all;

---------------------------------------------------------------------------------------------------
-- Entity
---------------------------------------------------------------------------------------------------
-- vunit: run_all_in_same_sim
entity olo_ft_ecc_monitor_axi_tb is
    generic (
        runner_cfg     : string;
        Channels_g     : positive range 1 to 255 := 8;
        CounterWidth_g : positive range 1 to 16  := 16
    );
end entity;

---------------------------------------------------------------------------------------------------
-- Architecture
---------------------------------------------------------------------------------------------------
architecture sim of olo_ft_ecc_monitor_axi_tb is

    -----------------------------------------------------------------------------------------------
    -- Constants
    -----------------------------------------------------------------------------------------------
    constant ClkPeriod_c     : time     := 10 ns;
    constant AxiAddrWidth_c  : positive := 12;
    constant CntBaseByte_c   : positive := 16;
    constant InfoAddr_c      : natural  := 16#00#;
    constant CtrlAddr_c      : natural  := 16#04#;
    constant IrqStatusAddr_c : natural  := 16#08#;
    constant IrqEnaAddr_c    : natural  := 16#0C#;

    constant Info_c : std_logic_vector(31 downto 0) :=
        toUslv(0, 19) & toUslv(CounterWidth_g, 5) & toUslv(Channels_g, 8);

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

    -- Expected counter word: [15:0] SEC count, [31:16] DED count
    function cntWord (sec : natural; ded : natural) return unsigned is
    begin
        return unsigned(toUslv(ded, 16) & toUslv(sec, 16));
    end function;

    -- Counter word address of a channel
    function cntAddr (channel : natural) return unsigned is
    begin
        return to_unsigned(CntBaseByte_c + 4 * channel, AxiAddrWidth_c);
    end function;

    -----------------------------------------------------------------------------------------------
    -- AXI Definition
    -----------------------------------------------------------------------------------------------
    constant IdWidth_c   : integer := 0;
    constant AddrWidth_c : integer := AxiAddrWidth_c;
    constant UserWidth_c : integer := 0;
    constant DataWidth_c : integer := 32;
    constant ByteWidth_c : integer := DataWidth_c / 8;

    subtype IdRange_c   is natural range IdWidth_c - 1 downto 0;
    subtype AddrRange_c is natural range AddrWidth_c - 1 downto 0;
    subtype UserRange_c is natural range UserWidth_c - 1 downto 0;
    subtype DataRange_c is natural range DataWidth_c - 1 downto 0;
    subtype ByteRange_c is natural range ByteWidth_c - 1 downto 0;

    signal AxiMs : axi_ms_t (ar_id(IdRange_c), aw_id(IdRange_c),
                              ar_addr(AddrRange_c), aw_addr(AddrRange_c),
                              ar_user(UserRange_c), aw_user(UserRange_c), w_user(UserRange_c),
                              w_data(DataRange_c),
                              w_strb(ByteRange_c));

    signal AxiSm : axi_sm_t (r_id(IdRange_c), b_id(IdRange_c),
                              r_user(UserRange_c), b_user(UserRange_c),
                              r_data(DataRange_c));

    -- *** Verification Components ***
    constant AxiMaster_c : olo_test_axi_master_t := new_olo_test_axi_master (
        data_width => DataWidth_c,
        addr_width => AddrWidth_c,
        id_width => IdWidth_c
    );

    -----------------------------------------------------------------------------------------------
    -- Interface Signals
    -----------------------------------------------------------------------------------------------
    signal Clk       : std_logic                                 := '0';
    signal Rst       : std_logic                                 := '1';
    signal In_EccSec : std_logic_vector(Channels_g - 1 downto 0) := (others => '0');
    signal In_EccDed : std_logic_vector(Channels_g - 1 downto 0) := (others => '0');
    signal In_Valid  : std_logic_vector(Channels_g - 1 downto 0) := (others => '1');
    signal Irq       : std_logic;

begin

    -----------------------------------------------------------------------------------------------
    -- Clock
    -----------------------------------------------------------------------------------------------
    Clk <= not Clk after 0.5 * ClkPeriod_c;

    -----------------------------------------------------------------------------------------------
    -- DUT
    -----------------------------------------------------------------------------------------------
    i_dut : entity olo.olo_ft_ecc_monitor_axi
        generic map (
            Channels_g     => Channels_g,
            CounterWidth_g => CounterWidth_g,
            AxiAddrWidth_g => AxiAddrWidth_c
        )
        port map (
            Clk               => Clk,
            Rst               => Rst,
            S_AxiLite_ArAddr  => AxiMs.ar_addr,
            S_AxiLite_ArValid => AxiMs.ar_valid,
            S_AxiLite_ArReady => AxiSm.ar_ready,
            S_AxiLite_AwAddr  => AxiMs.aw_addr,
            S_AxiLite_AwValid => AxiMs.aw_valid,
            S_AxiLite_AwReady => AxiSm.aw_ready,
            S_AxiLite_WData   => AxiMs.w_data,
            S_AxiLite_WStrb   => AxiMs.w_strb,
            S_AxiLite_WValid  => AxiMs.w_valid,
            S_AxiLite_WReady  => AxiSm.w_ready,
            S_AxiLite_BResp   => AxiSm.b_resp,
            S_AxiLite_BValid  => AxiSm.b_valid,
            S_AxiLite_BReady  => AxiMs.b_ready,
            S_AxiLite_RData   => AxiSm.r_data,
            S_AxiLite_RResp   => AxiSm.r_resp,
            S_AxiLite_RValid  => AxiSm.r_valid,
            S_AxiLite_RReady  => AxiMs.r_ready,
            In_EccSec         => In_EccSec,
            In_EccDed         => In_EccDed,
            In_Valid          => In_Valid,
            Irq               => Irq
        );

    -----------------------------------------------------------------------------------------------
    -- Verification Components
    -----------------------------------------------------------------------------------------------
    vc_master : entity work.olo_test_axi_lite_master_vc
        generic map (
            Instance => AxiMaster_c
        )
        port map (
            Clk    => Clk,
            Axi_Ms => AxiMs,
            Axi_Sm => AxiSm
        );

    -----------------------------------------------------------------------------------------------
    -- TB Control
    -----------------------------------------------------------------------------------------------
    test_runner_watchdog(runner, 50 ms);

    p_control : process is
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

            if run("InfoRegister") then
                expect_single_read(net, AxiMaster_c,
                    addr => to_unsigned(InfoAddr_c, AxiAddrWidth_c),
                    data => unsigned(Info_c));

            elsif run("CountAndRead") then
                pulseEvent(0, '1', '0', Clk, In_EccSec, In_EccDed);
                pulseEvent(0, '1', '0', Clk, In_EccSec, In_EccDed);
                pulseEvent(1, '0', '1', Clk, In_EccSec, In_EccDed);
                expect_single_read(net, AxiMaster_c, addr => cntAddr(0), data => cntWord(2, 0));
                expect_single_read(net, AxiMaster_c, addr => cntAddr(1), data => cntWord(0, 1));
                expect_single_read(net, AxiMaster_c, addr => cntAddr(2), data => cntWord(0, 0));

            elsif run("WriteClearsChannel") then
                pulseEvent(0, '1', '1', Clk, In_EccSec, In_EccDed);
                pulseEvent(1, '1', '0', Clk, In_EccSec, In_EccDed);
                push_single_write(net, AxiMaster_c, addr => cntAddr(0), data => to_unsigned(0, 32));
                wait_until_idle(net, as_sync(AxiMaster_c));
                expect_single_read(net, AxiMaster_c, addr => cntAddr(0), data => cntWord(0, 0));
                expect_single_read(net, AxiMaster_c, addr => cntAddr(1), data => cntWord(1, 0));

            elsif run("CtrlClearAll") then
                pulseEvent(0, '1', '1', Clk, In_EccSec, In_EccDed);
                pulseEvent(Channels_g - 1, '1', '1', Clk, In_EccSec, In_EccDed);
                push_single_write(net, AxiMaster_c,
                    addr => to_unsigned(CtrlAddr_c, AxiAddrWidth_c),
                    data => to_unsigned(1, 32));
                wait_until_idle(net, as_sync(AxiMaster_c));
                expect_single_read(net, AxiMaster_c, addr => cntAddr(0), data => cntWord(0, 0));
                expect_single_read(net, AxiMaster_c, addr => cntAddr(Channels_g - 1), data => cntWord(0, 0));

            elsif run("IrqFlow") then
                -- Latch-only while disabled
                pulseEvent(0, '1', '0', Clk, In_EccSec, In_EccDed);
                wait until rising_edge(Clk);
                wait until rising_edge(Clk);
                check_equal(Irq, '0', "Irq masked while disabled");
                expect_single_read(net, AxiMaster_c,
                    addr => to_unsigned(IrqStatusAddr_c, AxiAddrWidth_c),
                    data => to_unsigned(1, 32));
                -- Enable and check the pending status raises the interrupt
                push_single_write(net, AxiMaster_c,
                    addr => to_unsigned(IrqEnaAddr_c, AxiAddrWidth_c),
                    data => to_unsigned(3, 32));
                wait_until_idle(net, as_sync(AxiMaster_c));
                wait until rising_edge(Clk);
                wait until rising_edge(Clk);
                check_equal(Irq, '1', "Irq raised after enable");
                -- W1C clears the status and the interrupt
                push_single_write(net, AxiMaster_c,
                    addr => to_unsigned(IrqStatusAddr_c, AxiAddrWidth_c),
                    data => to_unsigned(1, 32));
                wait_until_idle(net, as_sync(AxiMaster_c));
                expect_single_read(net, AxiMaster_c,
                    addr => to_unsigned(IrqStatusAddr_c, AxiAddrWidth_c),
                    data => to_unsigned(0, 32));
                wait until rising_edge(Clk);
                check_equal(Irq, '0', "Irq cleared by W1C");
                -- DED event sets bit 1
                pulseEvent(1, '0', '1', Clk, In_EccSec, In_EccDed);
                wait until rising_edge(Clk);
                wait until rising_edge(Clk);
                check_equal(Irq, '1', "Irq raised by DED");
                expect_single_read(net, AxiMaster_c,
                    addr => to_unsigned(IrqStatusAddr_c, AxiAddrWidth_c),
                    data => to_unsigned(2, 32));

            elsif run("IrqEnaReadback") then
                push_single_write(net, AxiMaster_c,
                    addr => to_unsigned(IrqEnaAddr_c, AxiAddrWidth_c),
                    data => to_unsigned(2, 32));
                wait_until_idle(net, as_sync(AxiMaster_c));
                expect_single_read(net, AxiMaster_c,
                    addr => to_unsigned(IrqEnaAddr_c, AxiAddrWidth_c),
                    data => to_unsigned(2, 32));
                expect_single_read(net, AxiMaster_c,
                    addr => to_unsigned(CtrlAddr_c, AxiAddrWidth_c),
                    data => to_unsigned(0, 32));

            elsif run("SaturationViaAxi") then
                -- Saturating behavior observable through the register interface. The full
                -- saturation sweep only runs for narrow counters (bounded simulation time);
                -- wide counters are covered by the core test bench.
                if CounterWidth_g <= 8 then
                    wait until rising_edge(Clk);
                    In_EccSec(0) <= '1';

                    for i in 1 to 2**CounterWidth_g + 2 loop
                        wait until rising_edge(Clk);
                    end loop;

                    In_EccSec(0) <= '0';
                    expect_single_read(net, AxiMaster_c, addr => cntAddr(0),
                        data                                  => cntWord(2**CounterWidth_g - 1, 0));
                end if;
            end if;

            wait_until_idle(net, as_sync(AxiMaster_c));

        end loop;

        test_runner_cleanup(runner);
    end process;

end architecture;
