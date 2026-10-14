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
    context vunit_lib.com_context;
    context vunit_lib.vc_context;

library osvvm;
    use osvvm.RandomPkg.all;

library olo;
    use olo.olo_base_pkg_math.all;
    use olo.olo_base_pkg_logic.all;
    use olo.olo_axi_pkg_protocol.all;

library work;
    use work.olo_test_pkg_axi.all;
    use work.olo_test_axi_master_pkg.all;
    use work.olo_test_axi_slave_pkg.all;

---------------------------------------------------------------------------------------------------
-- Entity
---------------------------------------------------------------------------------------------------
-- vunit: run_all_in_same_sim
entity olo_axi_lite_decoder_tb is
    generic (
        AxiAddrWidth_g  : positive := 32;
        AxiDataWidth_g  : positive := 32;
        Ports_g         : positive := 3;
        PortAddrWidth_g : positive := 8;
        runner_cfg      : string
    );
end entity;

architecture sim of olo_axi_lite_decoder_tb is

    -----------------------------------------------------------------------------------------------
    -- AXI Definition
    -----------------------------------------------------------------------------------------------
    constant IdWidth_c   : integer := 0;
    constant UserWidth_c : integer := 0;
    constant ByteWidth_c : integer := AxiDataWidth_g/8;

    subtype IdRange_c       is natural range IdWidth_c-1 downto 0;
    subtype AddrRange_c     is natural range AxiAddrWidth_g-1 downto 0;
    subtype PortAddrRange_c is natural range PortAddrWidth_g-1 downto 0;
    subtype UserRange_c     is natural range UserWidth_c-1 downto 0;
    subtype DataRange_c     is natural range AxiDataWidth_g-1 downto 0;
    subtype ByteRange_c     is natural range ByteWidth_c-1 downto 0;

    signal AxiMs : axi_ms_t (ar_id(IdRange_c), aw_id(IdRange_c),
                              ar_addr(AddrRange_c), aw_addr(AddrRange_c),
                              ar_user(UserRange_c), aw_user(UserRange_c), w_user(UserRange_c),
                              w_data(DataRange_c),
                              w_strb(ByteRange_c));

    signal AxiSm : axi_sm_t (r_id(IdRange_c), b_id(IdRange_c),
                              r_user(UserRange_c), b_user(UserRange_c),
                              r_data(DataRange_c));

    -----------------------------------------------------------------------------------------------
    -- Constants
    -----------------------------------------------------------------------------------------------
    constant IdxBits_c     : natural := log2ceil(Ports_g);
    constant Windows_c     : natural := 2**IdxBits_c;
    constant UpperBits_c   : boolean := AxiAddrWidth_g > PortAddrWidth_g + IdxBits_c;
    constant ClkPeriod_c   : time    := 10 ns;
    constant OffsetLimit_c : natural := minimum(2**PortAddrWidth_g, 2**16);

    -----------------------------------------------------------------------------------------------
    -- TB Defnitions
    -----------------------------------------------------------------------------------------------

    -- *** Verification Compnents ***
    constant AxiMaster_c : olo_test_axi_master_t := new_olo_test_axi_master (
        data_width => AxiDataWidth_g,
        addr_width => AxiAddrWidth_g,
        id_width => IdWidth_c
    );

    type SlaveArray_t is array (natural range <>) of olo_test_axi_slave_t;

    impure function newSlaves return SlaveArray_t is
        variable Slaves_v : SlaveArray_t(0 to Ports_g - 1);
    begin

        for p in Slaves_v'range loop
            Slaves_v(p) := new_olo_test_axi_slave(AxiDataWidth_g, PortAddrWidth_g, IdWidth_c);
        end loop;

        return Slaves_v;
    end function;

    constant AxiSlaves_c : SlaveArray_t(0 to Ports_g - 1) := newSlaves;

    -- *** Functions ***
    -- Address on the slave port of the decoder for a slave port and an offset in its window
    function portAddr (
        port_idx : natural;
        offset   : natural;
        upper    : boolean := false) return unsigned is
        variable Addr_v : unsigned(AxiAddrWidth_g - 1 downto 0);
    begin
        Addr_v := to_unsigned(offset mod 2**PortAddrWidth_g, AxiAddrWidth_g);
        if IdxBits_c > 0 then
            Addr_v(PortAddrWidth_g + IdxBits_c - 1 downto PortAddrWidth_g) := to_unsigned(port_idx, IdxBits_c);
        end if;
        if upper then
            Addr_v(AxiAddrWidth_g - 1) := '1';
        end if;
        return Addr_v;
    end function;

    -- Offset of an address inside the window of a slave port
    function offsetAddr (offset : natural) return unsigned is
    begin
        return to_unsigned(offset mod 2**PortAddrWidth_g, PortAddrWidth_g);
    end function;

    -- Data of a test access
    function testData (value : natural) return unsigned is
    begin
        return to_unsigned(value mod 2**minimum(AxiDataWidth_g, 30), AxiDataWidth_g);
    end function;

    -- *** Procedures ***
    -- Write over the decoder and check it at the slave port
    procedure testWrite (
        signal net     : inout network_t;
        port_idx       : natural;
        offset         : natural;
        data           : natural;
        upper          : boolean := false;
        aw_valid_delay : time    := 0 ns;
        w_valid_delay  : time    := 0 ns;
        b_ready_delay  : time    := 0 ns;
        aw_ready_delay : time    := 0 ns;
        w_ready_delay  : time    := 0 ns;
        b_valid_delay  : time    := 0 ns) is
    begin
        push_single_write(net, AxiMaster_c, portAddr(port_idx, offset, upper), testData(data),
                          aw_valid_delay => aw_valid_delay, w_valid_delay => w_valid_delay,
                          b_ready_delay  => b_ready_delay);
        expect_single_write(net, AxiSlaves_c(port_idx), offsetAddr(offset), testData(data),
                            aw_ready_delay => aw_ready_delay, w_ready_delay => w_ready_delay,
                            b_valid_delay  => b_valid_delay);
    end procedure;

    -- Read over the decoder and check it at the slave port
    procedure testRead (
        signal net     : inout network_t;
        port_idx       : natural;
        offset         : natural;
        data           : natural;
        upper          : boolean := false;
        ar_valid_delay : time    := 0 ns;
        r_ready_delay  : time    := 0 ns;
        ar_ready_delay : time    := 0 ns;
        r_valid_delay  : time    := 0 ns) is
    begin
        expect_single_read(net, AxiMaster_c, portAddr(port_idx, offset, upper), testData(data),
                           ar_valid_delay => ar_valid_delay, r_ready_delay => r_ready_delay);
        push_single_read(net, AxiSlaves_c(port_idx), offsetAddr(offset), testData(data),
                         ar_ready_delay => ar_ready_delay, r_valid_delay => r_valid_delay);
    end procedure;

    -- Wait until all verification components are idle
    procedure waitIdle (
        signal net : inout network_t) is
    begin
        wait_until_idle(net, as_sync(AxiMaster_c));

        for p in 0 to Ports_g - 1 loop
            wait_until_idle(net, as_sync(AxiSlaves_c(p)));
        end loop;

    end procedure;

    -----------------------------------------------------------------------------------------------
    -- Interface Signals
    -----------------------------------------------------------------------------------------------
    signal Clk               : std_logic := '0';
    signal Rst               : std_logic := '0';
    signal M_AxiLite_ArAddr  : std_logic_vector(Ports_g * PortAddrWidth_g - 1 downto 0);
    signal M_AxiLite_ArValid : std_logic_vector(Ports_g - 1 downto 0);
    signal M_AxiLite_ArReady : std_logic_vector(Ports_g - 1 downto 0);
    signal M_AxiLite_AwAddr  : std_logic_vector(Ports_g * PortAddrWidth_g - 1 downto 0);
    signal M_AxiLite_AwValid : std_logic_vector(Ports_g - 1 downto 0);
    signal M_AxiLite_AwReady : std_logic_vector(Ports_g - 1 downto 0);
    signal M_AxiLite_WData   : std_logic_vector(Ports_g * AxiDataWidth_g - 1 downto 0);
    signal M_AxiLite_WStrb   : std_logic_vector(Ports_g * ByteWidth_c - 1 downto 0);
    signal M_AxiLite_WValid  : std_logic_vector(Ports_g - 1 downto 0);
    signal M_AxiLite_WReady  : std_logic_vector(Ports_g - 1 downto 0);
    signal M_AxiLite_BResp   : std_logic_vector(Ports_g * 2 - 1 downto 0);
    signal M_AxiLite_BValid  : std_logic_vector(Ports_g - 1 downto 0);
    signal M_AxiLite_BReady  : std_logic_vector(Ports_g - 1 downto 0);
    signal M_AxiLite_RData   : std_logic_vector(Ports_g * AxiDataWidth_g - 1 downto 0);
    signal M_AxiLite_RResp   : std_logic_vector(Ports_g * 2 - 1 downto 0);
    signal M_AxiLite_RValid  : std_logic_vector(Ports_g - 1 downto 0);
    signal M_AxiLite_RReady  : std_logic_vector(Ports_g - 1 downto 0);

    -- Number of address and data beats presented to any slave port
    signal SlaveBeats : natural := 0;

begin

    -----------------------------------------------------------------------------------------------
    -- TB Control
    -----------------------------------------------------------------------------------------------
    test_runner_watchdog(runner, 1 ms);

    p_control : process is
        variable Rand_v      : RandomPType;
        variable Port_v      : natural;
        variable Offset_v    : natural;
        variable Delay_v     : time;
        variable SlaveBeat_v : natural;
    begin
        test_runner_setup(runner, runner_cfg);
        Rand_v.InitSeed(Rand_v'instance_name);

        while test_suite loop

            -- Reset
            wait until rising_edge(Clk);
            Rst <= '1';
            wait for 200 ns;
            wait until rising_edge(Clk);
            Rst <= '0';
            wait until rising_edge(Clk);

            -- Reset values
            if run("ResetValues") then
                check_equal(AxiSm.ar_ready, '1', "S_AxiLite_ArReady");
                check_equal(AxiSm.aw_ready, '1', "S_AxiLite_AwReady");
                check_equal(AxiSm.w_ready, '1', "S_AxiLite_WReady");
                check_equal(AxiSm.b_valid, '0', "S_AxiLite_BValid");
                check_equal(AxiSm.r_valid, '0', "S_AxiLite_RValid");
                check_equal(M_AxiLite_ArValid, zerosVector(Ports_g), "M_AxiLite_ArValid");
                check_equal(M_AxiLite_AwValid, zerosVector(Ports_g), "M_AxiLite_AwValid");
                check_equal(M_AxiLite_WValid, zerosVector(Ports_g), "M_AxiLite_WValid");
                check_equal(M_AxiLite_BReady, zerosVector(Ports_g), "M_AxiLite_BReady");
                check_equal(M_AxiLite_RReady, zerosVector(Ports_g), "M_AxiLite_RReady");
            end if;

            -- Write and read every slave port at the lowest and the highest offset
            if run("Access-AllPorts") then

                for p in 0 to Ports_g - 1 loop
                    testWrite(net, p, 0, 16#100# + p);
                    testWrite(net, p, 2**PortAddrWidth_g - ByteWidth_c, 16#200# + p);
                end loop;

                for p in 0 to Ports_g - 1 loop
                    testRead(net, p, 0, 16#300# + p);
                    testRead(net, p, 2**PortAddrWidth_g - ByteWidth_c, 16#400# + p);
                end loop;

            end if;

            -- Address before data and data before address
            if run("Write-Order") then

                for p in 0 to Ports_g - 1 loop
                    testWrite(net, p, 4, 16#10# + p, w_valid_delay => 100 ns);
                    testWrite(net, p, 8, 16#20# + p, aw_valid_delay => 100 ns);
                end loop;

            end if;

            -- Byte strobes pass through
            if run("Write-Strobes") then

                for p in 0 to Ports_g - 1 loop
                    push_single_write(net, AxiMaster_c, portAddr(p, 12), testData(16#55# + p),
                                      strb => toUslv(1, ByteWidth_c));
                    expect_single_write(net, AxiSlaves_c(p), offsetAddr(12), testData(16#55# + p),
                                        strb => toUslv(1, ByteWidth_c));
                    push_single_write(net, AxiMaster_c, portAddr(p, 16), testData(16#66# + p),
                                      strb => toUslv(2**ByteWidth_c - 2, ByteWidth_c));
                    expect_single_write(net, AxiSlaves_c(p), offsetAddr(16), testData(16#66# + p),
                                        strb => toUslv(2**ByteWidth_c - 2, ByteWidth_c));
                end loop;

            end if;

            -- Handshake delays on the slave ports and on the master port
            if run("Handshake-Delays") then

                for p in 0 to Ports_g - 1 loop
                    testWrite(net, p, 20, 16#A0# + p, aw_ready_delay => 50 ns);
                    testWrite(net, p, 24, 16#B0# + p, w_ready_delay => 50 ns);
                    testWrite(net, p, 28, 16#C0# + p, b_valid_delay => 50 ns, b_ready_delay => 70 ns);
                    testRead(net, p, 20, 16#D0# + p, ar_ready_delay => 50 ns);
                    testRead(net, p, 24, 16#E0# + p, r_valid_delay => 50 ns, r_ready_delay => 70 ns);
                end loop;

            end if;

            -- Error responses of the slave ports are forwarded
            if run("Slave-Errors") then

                for p in 0 to Ports_g - 1 loop
                    -- Write with SLVERR
                    push_aw(net, AxiMaster_c, portAddr(p, 32));
                    push_w(net, AxiMaster_c, testData(p));
                    expect_b(net, AxiMaster_c, resp => AxiResp_SlvErr_c);
                    expect_aw(net, AxiSlaves_c(p), offsetAddr(32));
                    expect_w(net, AxiSlaves_c(p), testData(p));
                    push_b(net, AxiSlaves_c(p), resp => AxiResp_SlvErr_c);
                    -- Read with DECERR from a slave port behind it
                    push_ar(net, AxiMaster_c, portAddr(p, 36));
                    expect_r(net, AxiMaster_c, testData(16#77#), resp => AxiResp_DecErr_c);
                    expect_ar(net, AxiSlaves_c(p), offsetAddr(36));
                    push_r(net, AxiSlaves_c(p), testData(16#77#), error_code => AxiResp_DecErr_c);
                end loop;

            end if;

            -- Addresses beyond the last slave port: DECERR without access to any slave port
            if run("Unmapped-Address") then
                if Windows_c > Ports_g then
                    waitIdle(net);
                    SlaveBeat_v := SlaveBeats;

                    for w in Ports_g to Windows_c - 1 loop
                        push_aw(net, AxiMaster_c, portAddr(w, 40));
                        push_w(net, AxiMaster_c, testData(16#88#));
                        expect_b(net, AxiMaster_c, resp => AxiResp_DecErr_c, delay => 30 ns);
                        push_ar(net, AxiMaster_c, portAddr(w, 44));
                        expect_r(net, AxiMaster_c, to_unsigned(0, AxiDataWidth_g), resp => AxiResp_DecErr_c);
                    end loop;

                    -- No slave port saw an access, mapped accesses still work afterwards
                    waitIdle(net);
                    check_equal(SlaveBeats, SlaveBeat_v, "unmapped access reached a slave port");
                    testWrite(net, Ports_g - 1, 48, 16#99#);
                    testRead(net, Ports_g - 1, 48, 16#9A#);
                else
                    info("All address windows are populated: no unmapped address");
                end if;
            end if;

            -- Address bits above the port index are ignored
            if run("Address-UpperBits") then
                if UpperBits_c then
                    testWrite(net, Ports_g - 1, 52, 16#5A#, upper => true);
                    testRead(net, Ports_g - 1, 52, 16#A5#, upper => true);
                else
                    info("No address bits above the port index");
                end if;
            end if;

            -- Read and write at the same time, to the same and to different slave ports
            if run("Concurrent-ReadWrite") then

                for p in 0 to Ports_g - 1 loop
                    testWrite(net, p, 56, 16#C1# + p, b_valid_delay => 40 ns);
                    testRead(net, (p + 1) mod Ports_g, 60, 16#D1# + p, r_valid_delay => 30 ns);
                    testWrite(net, p, 64, 16#E1# + p);
                    testRead(net, p, 64, 16#F1# + p);
                end loop;

            end if;

            -- Random sequence of accesses and handshake delays
            if run("Random-Accesses") then

                for i in 0 to 99 loop
                    Port_v   := Rand_v.RandInt(0, Ports_g - 1);
                    Offset_v := Rand_v.RandInt(0, OffsetLimit_c / ByteWidth_c - 1) * ByteWidth_c;
                    Delay_v  := Rand_v.RandInt(0, 4) * ClkPeriod_c;
                    if Rand_v.RandInt(0, 1) = 0 then
                        testWrite(net, Port_v, Offset_v, i,
                                  aw_valid_delay => Delay_v, w_ready_delay => Delay_v,
                                  b_valid_delay  => Rand_v.RandInt(0, 3) * ClkPeriod_c);
                    else
                        testRead(net, Port_v, Offset_v, i,
                                 r_ready_delay => Delay_v, ar_ready_delay => Rand_v.RandInt(0, 3) * ClkPeriod_c);
                    end if;
                end loop;

            end if;

            waitIdle(net);
            wait for 1 us;

        end loop;

        -- TB done
        test_runner_cleanup(runner);
    end process;

    -----------------------------------------------------------------------------------------------
    -- Monitor: address and data beats presented to the slave ports
    -----------------------------------------------------------------------------------------------
    p_monitor : process (Clk) is
    begin
        if rising_edge(Clk) then
            if unsigned(M_AxiLite_ArValid) /= 0 or unsigned(M_AxiLite_AwValid) /= 0 or
               unsigned(M_AxiLite_WValid) /= 0 then
                SlaveBeats <= SlaveBeats + 1;
            end if;
        end if;
    end process;

    -----------------------------------------------------------------------------------------------
    -- Clock
    -----------------------------------------------------------------------------------------------
    Clk <= not Clk after 0.5 * ClkPeriod_c;

    -----------------------------------------------------------------------------------------------
    -- DUT
    -----------------------------------------------------------------------------------------------
    i_dut : entity olo.olo_axi_lite_decoder
        generic map (
            AxiAddrWidth_g  => AxiAddrWidth_g,
            AxiDataWidth_g  => AxiDataWidth_g,
            Ports_g         => Ports_g,
            PortAddrWidth_g => PortAddrWidth_g
        )
        port map (
            Clk               => Clk,
            Rst               => Rst,
            -- Slave interface
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
            -- Master interfaces
            M_AxiLite_ArAddr  => M_AxiLite_ArAddr,
            M_AxiLite_ArValid => M_AxiLite_ArValid,
            M_AxiLite_ArReady => M_AxiLite_ArReady,
            M_AxiLite_AwAddr  => M_AxiLite_AwAddr,
            M_AxiLite_AwValid => M_AxiLite_AwValid,
            M_AxiLite_AwReady => M_AxiLite_AwReady,
            M_AxiLite_WData   => M_AxiLite_WData,
            M_AxiLite_WStrb   => M_AxiLite_WStrb,
            M_AxiLite_WValid  => M_AxiLite_WValid,
            M_AxiLite_WReady  => M_AxiLite_WReady,
            M_AxiLite_BResp   => M_AxiLite_BResp,
            M_AxiLite_BValid  => M_AxiLite_BValid,
            M_AxiLite_BReady  => M_AxiLite_BReady,
            M_AxiLite_RData   => M_AxiLite_RData,
            M_AxiLite_RResp   => M_AxiLite_RResp,
            M_AxiLite_RValid  => M_AxiLite_RValid,
            M_AxiLite_RReady  => M_AxiLite_RReady
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

    g_slaves : for p in 0 to Ports_g - 1 generate

        signal SlvMs : axi_ms_t (ar_id(IdRange_c), aw_id(IdRange_c),
                                  ar_addr(PortAddrRange_c), aw_addr(PortAddrRange_c),
                                  ar_user(UserRange_c), aw_user(UserRange_c), w_user(UserRange_c),
                                  w_data(DataRange_c),
                                  w_strb(ByteRange_c));

        signal SlvSm : axi_sm_t (r_id(IdRange_c), b_id(IdRange_c),
                                  r_user(UserRange_c), b_user(UserRange_c),
                                  r_data(DataRange_c));

    begin

        -- AXI-Lite subset of the slave port, the remaining AXI4 signals are constant
        SlvMs.ar_id     <= (others => '0');
        SlvMs.ar_addr   <= M_AxiLite_ArAddr((p + 1) * PortAddrWidth_g - 1 downto p * PortAddrWidth_g);
        SlvMs.ar_len    <= (others => '0');
        SlvMs.ar_size   <= toUslv(log2(ByteWidth_c), 3);
        SlvMs.ar_burst  <= AxiBurst_Incr_c;
        SlvMs.ar_lock   <= '0';
        SlvMs.ar_cache  <= (others => '0');
        SlvMs.ar_prot   <= (others => '0');
        SlvMs.ar_qos    <= (others => '0');
        SlvMs.ar_region <= (others => '0');
        SlvMs.ar_user   <= (others => '0');
        SlvMs.ar_valid  <= M_AxiLite_ArValid(p);
        SlvMs.r_ready   <= M_AxiLite_RReady(p);
        SlvMs.aw_id     <= (others => '0');
        SlvMs.aw_addr   <= M_AxiLite_AwAddr((p + 1) * PortAddrWidth_g - 1 downto p * PortAddrWidth_g);
        SlvMs.aw_len    <= (others => '0');
        SlvMs.aw_size   <= toUslv(log2(ByteWidth_c), 3);
        SlvMs.aw_burst  <= AxiBurst_Incr_c;
        SlvMs.aw_lock   <= '0';
        SlvMs.aw_cache  <= (others => '0');
        SlvMs.aw_prot   <= (others => '0');
        SlvMs.aw_qos    <= (others => '0');
        SlvMs.aw_region <= (others => '0');
        SlvMs.aw_user   <= (others => '0');
        SlvMs.aw_valid  <= M_AxiLite_AwValid(p);
        SlvMs.w_data    <= M_AxiLite_WData((p + 1) * AxiDataWidth_g - 1 downto p * AxiDataWidth_g);
        SlvMs.w_strb    <= M_AxiLite_WStrb((p + 1) * ByteWidth_c - 1 downto p * ByteWidth_c);
        SlvMs.w_last    <= '1';
        SlvMs.w_user    <= (others => '0');
        SlvMs.w_valid   <= M_AxiLite_WValid(p);
        SlvMs.b_ready   <= M_AxiLite_BReady(p);

        M_AxiLite_ArReady(p)                                                    <= SlvSm.ar_ready;
        M_AxiLite_RData((p + 1) * AxiDataWidth_g - 1 downto p * AxiDataWidth_g) <= SlvSm.r_data;
        M_AxiLite_RResp(2 * p + 1 downto 2 * p)                                 <= SlvSm.r_resp;
        M_AxiLite_RValid(p)                                                     <= SlvSm.r_valid;
        M_AxiLite_AwReady(p)                                                    <= SlvSm.aw_ready;
        M_AxiLite_WReady(p)                                                     <= SlvSm.w_ready;
        M_AxiLite_BResp(2 * p + 1 downto 2 * p)                                 <= SlvSm.b_resp;
        M_AxiLite_BValid(p)                                                     <= SlvSm.b_valid;

        vc_slave : entity work.olo_test_axi_slave_vc
            generic map (
                Instance => AxiSlaves_c(p)
            )
            port map (
                Clk    => Clk,
                Axi_Ms => SlvMs,
                Axi_Sm => SlvSm
            );

    end generate;

end architecture;
