---------------------------------------------------------------------------------------------------
-- Copyright (c) 2024 by Oliver Bruendler, Switzerland
-- Authors: Oliver Bruendler
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

library olo;
    use olo.olo_base_pkg_math.all;
    use olo.olo_base_pkg_logic.all;
    use olo.olo_axi_pkg_protocol.all;

library work;
    use work.olo_test_pkg_axi.all;
    use work.olo_test_axi_slave_pkg.all;

---------------------------------------------------------------------------------------------------
-- Entity
---------------------------------------------------------------------------------------------------
-- vunit: run_all_in_same_sim
entity olo_axi_master_simple_tb is
    generic (
        AxiAddrWidth_g              : natural range 12 to 64  := 32;
        AxiDataWidth_g              : natural range 8 to 1024 := 32;
        AxiMaxBeats_g               : natural range 1 to 256  := 32;
        AxiMaxOpenTransactions_g    : natural range 1 to 8    := 2;
        ImplRead_g                  : boolean                 := true;
        ImplWrite_g                 : boolean                 := true;
        RamBehavior_g               : string                  := "RBW";
        UserTransactionSizeBits_g   : natural range 1 to 16   := 10;
        -- Direction of the first commands after the power-up (test FirstCommands)
        ReadFirst_g                 : boolean                 := false;
        runner_cfg                  : string
    );
end entity;

architecture sim of olo_axi_master_simple_tb is

    -----------------------------------------------------------------------------------------------
    -- Fixed Generics
    -----------------------------------------------------------------------------------------------
    constant UserTransactionSizeBits_c : natural := UserTransactionSizeBits_g;
    constant DataFifoDepth_c           : natural := 16;
    -- Transfers split at AxiMaxBeats_g, limited to the largest command size
    constant MaxTfBeats_c              : natural := minimum(AxiMaxBeats_g*2+5, 2**UserTransactionSizeBits_g - 1);

    -- Tests with a fixed burst structure (error responses, full FIFO) use bursts of up to DataFifoDepth_c beats
    constant FixedBursts_c : boolean := AxiMaxBeats_g >= DataFifoDepth_c;

    -- FIXED bursts (CmdWr_Fixed, CmdRd_Fixed): at most 16 beats (AXI4), long commands limited by the command size
    constant FixedMaxBeats_c  : natural                := minimum(AxiMaxBeats_g, 16);
    constant FixedLongBeats_c : natural                := minimum(300, 2**UserTransactionSizeBits_g - 1);
    constant FixedSizes_c     : integer_vector(0 to 3) := (1, 16, 17, FixedLongBeats_c);

    -----------------------------------------------------------------------------------------------
    -- AXI Definition
    -----------------------------------------------------------------------------------------------
    constant ByteWidth_c : integer := AxiDataWidth_g/8;

    subtype IdRange_c   is natural range -1 downto 0;
    subtype AddrRange_c is natural range AxiAddrWidth_g-1 downto 0;
    subtype UserRange_c is natural range 1 downto 0;
    subtype DataRange_c is natural range AxiDataWidth_g-1 downto 0;
    subtype ByteRange_c is natural range ByteWidth_c-1 downto 0;

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
    subtype CmdAddrRange_c is natural range AxiAddrWidth_g-1 downto 0;
    subtype CmdSizeRange_c is natural range UserTransactionSizeBits_c+CmdAddrRange_c'high downto CmdAddrRange_c'high+1;
    constant CmdLowLat_c : natural := CmdSizeRange_c'high+1;
    constant CmdFixed_c  : natural := CmdLowLat_c+1;

    subtype DatDataRange_c is natural range AxiDataWidth_g-1 downto 0;
    subtype DatBeRange_c is natural range AxiDataWidth_g/8+DatDataRange_c'high downto DatDataRange_c'high+1;

    -----------------------------------------------------------------------------------------------
    -- TB Defnitions
    -----------------------------------------------------------------------------------------------
    constant Clk_Frequency_c : real := 100.0e6;
    constant Clk_Period_c    : time := (1 sec) / Clk_Frequency_c;

    type Response_t is (RespSuccess, RespError);

    -----------------------------------------------------------------------------------------------
    -- Interface Signals
    -----------------------------------------------------------------------------------------------
    signal Clk          : std_logic                                                := '0';
    signal Rst          : std_logic                                                := '0';
    signal CmdWr_Addr   : std_logic_vector(AxiAddrWidth_g - 1 downto 0)            := (others => '0');
    signal CmdWr_Size   : std_logic_vector(UserTransactionSizeBits_c - 1 downto 0) := (others => '0');
    signal CmdWr_LowLat : std_logic                                                := '0';
    signal CmdWr_Fixed  : std_logic                                                := '0';
    signal CmdWr_Valid  : std_logic                                                := '0';
    signal CmdWr_Ready  : std_logic;
    signal CmdRd_Addr   : std_logic_vector(AxiAddrWidth_g - 1 downto 0)            := (others => '0');
    signal CmdRd_Size   : std_logic_vector(UserTransactionSizeBits_c - 1 downto 0) := (others => '0');
    signal CmdRd_LowLat : std_logic                                                := '0';
    signal CmdRd_Fixed  : std_logic                                                := '0';
    signal CmdRd_Valid  : std_logic                                                := '0';
    signal CmdRd_Ready  : std_logic;
    signal Wr_Data      : std_logic_vector(AxiDataWidth_g - 1 downto 0)            := (others => '0');
    signal Wr_Be        : std_logic_vector(AxiDataWidth_g / 8 - 1 downto 0)        := (others => '0');
    signal Wr_Valid     : std_logic                                                := '0';
    signal Wr_Ready     : std_logic;
    signal Rd_Data      : std_logic_vector(AxiDataWidth_g - 1 downto 0);
    signal Rd_Valid     : std_logic;
    signal Rd_Ready     : std_logic                                                := '0';
    signal Wr_Done      : std_logic;
    signal Wr_Error     : std_logic;
    signal Wr_ErrorResp : std_logic_vector(1 downto 0);
    signal Rd_Done      : std_logic;
    signal Rd_Error     : std_logic;
    signal Rd_ErrorResp : std_logic_vector(1 downto 0);
    signal Rd_Last      : std_logic;

    -----------------------------------------------------------------------------------------------
    -- TB Defnitions
    -----------------------------------------------------------------------------------------------

    -- *** Verification Compnents ***
    constant AxiSlave_c     : olo_test_axi_slave_t := new_olo_test_axi_slave (
        data_width => AxiDataWidth_g,
        addr_width => AxiAddrWidth_g,
        id_width => 0
    );
    constant RdDataSlave_c  : axi_stream_slave_t   := new_axi_stream_slave (
        data_length => AxiDataWidth_g,
        stall_config => new_stall_config(0.0, 0, 0)
    );
    constant WrCmdMaster_c  : axi_stream_master_t  := new_axi_stream_master (
        data_length => AxiAddrWidth_g+UserTransactionSizeBits_c+2,
        stall_config => new_stall_config(0.0, 0, 0)
    );
    constant RdCmdMaster_c  : axi_stream_master_t  := new_axi_stream_master (
        data_length => AxiAddrWidth_g+UserTransactionSizeBits_c+2,
        stall_config => new_stall_config(0.0, 0, 0)
    );
    constant WrDataMaster_c : axi_stream_master_t  := new_axi_stream_master (
        data_length => AxiDataWidth_g+AxiDataWidth_g/8,
        stall_config => new_stall_config(0.0, 0, 0)
    );

    procedure pushCommand (
        signal net : inout network_t;
        CmdMaster  : axi_stream_master_t;
        CmdAddr    : unsigned;
        CmdSize    : integer;
        CmdLowLat  : std_logic := '0';
        CmdFixed   : std_logic := '0') is
        variable TData_v : std_logic_vector(CmdFixed_c downto 0);
    begin
        TData_v(CmdAddrRange_c) := std_logic_vector(resize(CmdAddr, AxiAddrWidth_g));
        TData_v(CmdSizeRange_c) := toUslv(CmdSize, UserTransactionSizeBits_c);
        TData_v(CmdLowLat_c)    := CmdLowLat;
        TData_v(CmdFixed_c)     := CmdFixed;
        push_axi_stream(net, CmdMaster, TData_v);
    end procedure;

    procedure pushWrData (
        signal net : inout network_t;
        startValue : unsigned;
        increment  : natural          := 1;
        beats      : natural          := 1;
        firstStrb  : std_logic_vector := onesVector(AxiDataWidth_g/8);
        lastStrb   : std_logic_vector := onesVector(AxiDataWidth_g/8)) is
        variable TData_v : std_logic_vector(DatBeRange_c'high downto 0);
        variable Data_v  : unsigned(AxiDataWidth_g-1 downto 0);
    begin
        Data_v := resize(startValue, AxiDataWidth_g);

        -- loop through beats
        for i in 0 to beats-1 loop
            TData_v(DatDataRange_c) := std_logic_vector(Data_v);
            if i = 0 then
                TData_v(DatBeRange_c) := firstStrb;
            elsif i = beats-1 then
                TData_v(DatBeRange_c) := lastStrb;
            else
                TData_v(DatBeRange_c) := (others => '1');
            end if;
            push_axi_stream(net, WrDataMaster_c, TData_v);
            Data_v := Data_v + increment;
        end loop;

    end procedure;

    procedure expectRdData (
        signal net : inout network_t;
        startValue : unsigned;
        increment  : natural := 1;
        beats      : natural := 1) is
        variable Data_v : unsigned(AxiDataWidth_g-1 downto 0);
        variable Last_v : std_logic := '0';
    begin
        Data_v := resize(startValue, AxiDataWidth_g);

        -- loop through beats
        for i in 0 to beats-1 loop
            -- Last is set on the last beat
            if i = beats-1 then
                Last_v := '1';
            end if;
            check_axi_stream(net, RdDataSlave_c, std_logic_vector(Data_v), blocking => false, tlast => Last_v, msg => "RdData " & integer'image(i));
            Data_v := Data_v + increment;
        end loop;

    end procedure;

    -- Expect a burst write on AXI, split into transactions of at most AxiMaxBeats_g beats within 4 KB
    -- .. fixed: FIXED bursts of at most FixedMaxBeats_c beats, all at addr, not split at 4 KB
    procedure expectAxiWrite (
        signal net : inout network_t;
        addr       : unsigned;
        startValue : unsigned;
        beats      : natural;
        beatDelay  : time    := 0 ns;
        fixed      : boolean := false) is
        variable Addr_v  : unsigned(AxiAddrWidth_g-1 downto 0);
        variable Data_v  : unsigned(AxiDataWidth_g-1 downto 0);
        variable Left_v  : natural := beats;
        variable Beats_v : natural;
        variable To4k_v  : natural;
    begin
        Addr_v := resize(addr, AxiAddrWidth_g);
        Data_v := resize(startValue, AxiDataWidth_g);

        -- loop through transactions
        while Left_v > 0 loop
            if fixed then
                Beats_v := minimum(Left_v, FixedMaxBeats_c);
                expect_burst_write_aligned(net, AxiSlave_c, Addr_v, Data_v, 1, Beats_v,
                                           beat_delay => beatDelay, burst => AxiBurst_Fixed_c);
            else
                -- AXI bursts must not cross a 4 KB boundary
                To4k_v  := (4096 - to_integer(Addr_v(11 downto 0))) / ByteWidth_c;
                Beats_v := minimum(minimum(Left_v, AxiMaxBeats_g), To4k_v);
                expect_burst_write_aligned(net, AxiSlave_c, Addr_v, Data_v, 1, Beats_v, beat_delay => beatDelay);
                Addr_v  := Addr_v + Beats_v*ByteWidth_c;
            end if;
            Data_v := Data_v + Beats_v;
            Left_v := Left_v - Beats_v;
        end loop;

    end procedure;

    -- Push a burst read on AXI, split into transactions of at most AxiMaxBeats_g beats within 4 KB
    -- .. fixed: FIXED bursts of at most FixedMaxBeats_c beats, all at addr, not split at 4 KB
    procedure pushAxiRead (
        signal net : inout network_t;
        addr       : unsigned;
        startValue : unsigned;
        beats      : natural;
        beatDelay  : time    := 0 ns;
        fixed      : boolean := false) is
        variable Addr_v  : unsigned(AxiAddrWidth_g-1 downto 0);
        variable Data_v  : unsigned(AxiDataWidth_g-1 downto 0);
        variable Left_v  : natural := beats;
        variable Beats_v : natural;
        variable To4k_v  : natural;
    begin
        Addr_v := resize(addr, AxiAddrWidth_g);
        Data_v := resize(startValue, AxiDataWidth_g);

        -- loop through transactions
        while Left_v > 0 loop
            if fixed then
                Beats_v := minimum(Left_v, FixedMaxBeats_c);
                push_burst_read_aligned(net, AxiSlave_c, Addr_v, Data_v, 1, Beats_v,
                                        beat_delay => beatDelay, burst => AxiBurst_Fixed_c);
            else
                -- AXI bursts must not cross a 4 KB boundary
                To4k_v  := (4096 - to_integer(Addr_v(11 downto 0))) / ByteWidth_c;
                Beats_v := minimum(minimum(Left_v, AxiMaxBeats_g), To4k_v);
                push_burst_read_aligned(net, AxiSlave_c, Addr_v, Data_v, 1, Beats_v, beat_delay => beatDelay);
                Addr_v  := Addr_v + Beats_v*ByteWidth_c;
            end if;
            Data_v := Data_v + Beats_v;
            Left_v := Left_v - Beats_v;
        end loop;

    end procedure;

    -- Code: expected response code of a failed command (Wr_ErrorResp, Rd_ErrorResp)
    procedure expectWrResponse (
        Response : Response_t;
        Code     : std_logic_vector(1 downto 0) := AxiResp_SlvErr_c) is
    begin
        wait until rising_edge(Clk) and ((Wr_Done = '1') or (Wr_Error = '1'));
        if Response = RespSuccess then
            check_equal(Wr_Error, '0', "Wrong Wr_Error");
            check_equal(Wr_Done, '1', "Wrong Wr_Done");
            check_equal(Wr_ErrorResp, AxiResp_Okay_c, "Wrong Wr_ErrorResp");
        else
            check_equal(Wr_Error, '1', "Wrong Wr_Error");
            check_equal(Wr_Done, '0', "Wrong Wr_Done");
            check_equal(Wr_ErrorResp, Code, "Wrong Wr_ErrorResp");
        end if;
    end procedure;

    procedure expectRdResponse (
        Response : Response_t;
        Code     : std_logic_vector(1 downto 0) := AxiResp_SlvErr_c) is
    begin
        wait until rising_edge(Clk) and ((Rd_Done = '1') or (Rd_Error = '1'));
        if Response = RespSuccess then
            check_equal(Rd_Error, '0', "Wrong Rd_Error");
            check_equal(Rd_Done, '1', "Wrong Rd_Done");
            check_equal(Rd_ErrorResp, AxiResp_Okay_c, "Wrong Rd_ErrorResp");
        else
            check_equal(Rd_Error, '1', "Wrong Rd_Error");
            check_equal(Rd_Done, '0', "Wrong Rd_Done");
            check_equal(Rd_ErrorResp, Code, "Wrong Rd_ErrorResp");
        end if;
    end procedure;

begin

    -----------------------------------------------------------------------------------------------
    -- TB Control
    -----------------------------------------------------------------------------------------------
    test_runner_watchdog(runner, 1 ms);

    p_control : process is
        variable Undefined_v : std_logic_vector(3 downto 0);
        variable Reads_v     : boolean;
    begin
        test_runner_setup(runner, runner_cfg);

        while test_suite loop

            -- Reset
            wait until rising_edge(Clk);
            Rst <= '1';
            wait for 1 us;
            wait until rising_edge(Clk);
            Rst <= '0';
            wait until rising_edge(Clk);

            -- *** First commands after the power-up ***
            -- Only the first test of a simulation finds the registers of the master as after the power-up, so this
            -- test comes first. ReadFirst_g selects the direction of the first commands. The configurations
            -- ieee_warnings-* enable the IEEE warnings, and their post check fails on a numeric_std metavalue warning
            -- after the marker: no register may be converted while it is undefined (until the first command of its
            -- direction). The metavalue of Undefined_v before the marker shows that the warnings are enabled.
            -- Commands back to back: a single beat, a burst over a 4 KB boundary, a FIXED burst and the largest
            -- transfer (low latency: it does not fit into the FIFO).
            if run("FirstCommands") then
                check_equal(to_integer(unsigned(Undefined_v)), 0, "IEEE warning control");
                report "OLO_IEEE_CHECK_START";
                wait for 1 us;

                for Phase in 0 to 1 loop
                    Reads_v := (Phase = 1) xor ReadFirst_g;
                    if Reads_v and ImplRead_g then
                        push_single_read (net, AxiSlave_c, X"2080", X"4141");
                        pushCommand(net, RdCmdMaster_c, X"2080", 1);
                        expectRdData(net, X"4141");
                        pushAxiRead(net, X"2000"-2*AxiDataWidth_g/8, X"09", 2);
                        pushAxiRead(net, X"2000", X"0B", 6);
                        pushCommand(net, RdCmdMaster_c, X"2000"-2*AxiDataWidth_g/8, 8);
                        expectRdData(net, X"09", 1, 8);
                        pushAxiRead(net, X"0300", X"6B00", FixedSizes_c(2), fixed => true);
                        pushCommand(net, RdCmdMaster_c, X"0300", FixedSizes_c(2), CmdFixed => '1');
                        expectRdData(net, X"6B00", 1, FixedSizes_c(2));
                        pushAxiRead(net, X"0200", X"10EF", MaxTfBeats_c);
                        pushCommand(net, RdCmdMaster_c, X"0200", MaxTfBeats_c, CmdLowLat => '1');
                        expectRdData(net, X"10EF", 1, MaxTfBeats_c);

                        for i in 0 to 3 loop
                            expectRdResponse(RespSuccess);
                        end loop;

                        wait for 1 us;
                    elsif (not Reads_v) and ImplWrite_g then
                        expect_single_write (net, AxiSlave_c, X"1080", X"3131");
                        pushCommand(net, WrCmdMaster_c, X"1080", 1);
                        pushWrData(net, X"3131");
                        expectAxiWrite(net, X"1000"-2*AxiDataWidth_g/8, X"1234", 2);
                        expectAxiWrite(net, X"1000", X"1236", 6);
                        pushCommand(net, WrCmdMaster_c, X"1000"-2*AxiDataWidth_g/8, 8);
                        pushWrData(net, X"1234", 1, 8);
                        expectAxiWrite(net, X"0300", X"5A00", FixedSizes_c(2), fixed => true);
                        pushCommand(net, WrCmdMaster_c, X"0300", FixedSizes_c(2), CmdFixed => '1');
                        pushWrData(net, X"5A00", 1, FixedSizes_c(2));
                        expectAxiWrite(net, X"0100", X"7100", MaxTfBeats_c);
                        pushCommand(net, WrCmdMaster_c, X"0100", MaxTfBeats_c, CmdLowLat => '1');
                        pushWrData(net, X"7100", 1, MaxTfBeats_c);

                        for i in 0 to 3 loop
                            expectWrResponse(RespSuccess);
                        end loop;

                        wait for 1 us;
                    end if;
                end loop;

            end if;

            if run("ResetValues") then
                if ImplRead_g then
                    check_equal(Rd_Valid, '0', "Rd_Valid");
                    check_equal(Rd_Done, '0', "Rd_Done");
                    check_equal(Rd_Error, '0', "Rd_Error");
                end if;
                if ImplWrite_g then
                    check_equal(Wr_Done, '0', "Wr_Done");
                    check_equal(Wr_Error, '0', "Wr_Error");
                end if;

            end if;

            -- *** A command that is valid while the reset is released is executed once ***
            -- The command source is outside the reset of the master: command A is valid during the reset and in the
            -- first clock cycle after it, command B follows. A second execution of A would take the place of B. The
            -- write data follow the reset (the master discards inputs during its reset). The addresses are aligned
            -- for every AxiDataWidth_g (128 bytes).
            if run("CommandAtResetRelease") then
                if ImplWrite_g then
                    wait until rising_edge(Clk);
                    Rst <= '1';
                    expect_single_write (net, AxiSlave_c, X"1080", X"3131");
                    expect_single_write (net, AxiSlave_c, X"1100", X"5151");
                    pushCommand(net, WrCmdMaster_c, X"1080", 1);
                    wait for 1 us;
                    wait until rising_edge(Clk);
                    Rst <= '0';
                    pushWrData(net, X"3131");
                    pushCommand(net, WrCmdMaster_c, X"1100", 1);
                    pushWrData(net, X"5151");
                    expectWrResponse(RespSuccess);
                    expectWrResponse(RespSuccess);
                end if;
                if ImplRead_g then
                    wait until rising_edge(Clk);
                    Rst <= '1';
                    push_single_read (net, AxiSlave_c, X"2080", X"4141");
                    push_single_read (net, AxiSlave_c, X"2100", X"6161");
                    pushCommand(net, RdCmdMaster_c, X"2080", 1);
                    wait for 1 us;
                    wait until rising_edge(Clk);
                    Rst <= '0';
                    pushCommand(net, RdCmdMaster_c, X"2100", 1);
                    expectRdData(net, X"4141");
                    expectRdData(net, X"6161");
                    expectRdResponse(RespSuccess);
                    expectRdResponse(RespSuccess);
                end if;
            end if;

            -- *** Single Writes ***
            if run("SingleWrite-DataCmdTogether") then
                -- Only applies if Write is implemented
                if ImplWrite_g then

                    -- Both latency modes
                    for LowLatency in 0 to 1 loop
                        -- Slave
                        expect_single_write (net, AxiSlave_c, X"1080", X"ABCD");
                        -- Master
                        pushCommand(net, WrCmdMaster_c, X"1080", 1, CmdLowLat => choose(LowLatency=1, '1', '0'));
                        pushWrData(net, X"ABCD");
                        -- Blocking
                        expectWrResponse(RespSuccess);
                    end loop;

                end if;
            end if;

            if run("SingleWrite-DataBeforeCmd") then
                -- Only applies if Write is implemented
                if ImplWrite_g then

                    -- Both latency modes
                    for LowLatency in 0 to 1 loop
                        -- Slave
                        expect_single_write (net, AxiSlave_c, X"1100", X"ABC1");
                        -- Master
                        pushWrData(net, X"ABC1");
                        wait for 200 ns;
                        pushCommand(net, WrCmdMaster_c, X"1100", 1, CmdLowLat => choose(LowLatency=1, '1', '0'));
                        -- Blocking
                        expectWrResponse(RespSuccess);
                    end loop;

                end if;
            end if;

            if run("SingleWrite-CmdBeforeData") then
                if ImplWrite_g then

                    -- Both latency modes
                    for LowLatency in 0 to 1 loop
                        -- Master
                        pushCommand(net, WrCmdMaster_c, X"1180", 1, CmdLowLat => choose(LowLatency=1, '1', '0'));
                        wait for 200 ns;
                        if LowLatency = 0 then
                            check_equal(AxiMs.aw_valid, '0', "HighLatency write executed before data was present");
                        else
                            check_equal(AxiMs.aw_valid, '1', "LowLatency write not executed before data was present");
                        end if;
                        pushWrData(net, X"ABC2");
                        -- Slave
                        expect_single_write (net, AxiSlave_c, X"1180", X"ABC2");
                        -- Blocking
                        expectWrResponse(RespSuccess);
                    end loop;

                end if;
            end if;

            if run("SingleWrite-DelayedAwReady") then
                if ImplWrite_g then
                    -- Slave
                    expect_single_write (net, AxiSlave_c, X"0100", X"03", aw_ready_delay => 200 ns);
                    -- Master
                    pushCommand(net, WrCmdMaster_c, X"0100", 1);
                    pushWrData(net, X"03");
                    -- Blocking
                    expectWrResponse(RespSuccess);
                end if;
            end if;

            if run("SingleWrite-DelayedWReady") then
                if ImplWrite_g then
                    -- Slave
                    expect_single_write (net, AxiSlave_c, X"0200", X"04", w_ready_delay => 200 ns);
                    -- Master
                    pushCommand(net, WrCmdMaster_c, X"0200", 1);
                    pushWrData(net, X"04");
                    -- Blocking
                    expectWrResponse(RespSuccess);
                end if;
            end if;

            if run("SingleWrite-DelayedBValid") then
                if ImplWrite_g then
                    -- Slave
                    expect_single_write (net, AxiSlave_c, X"0280", X"05", b_valid_delay => 200 ns);
                    -- Master
                    pushCommand(net, WrCmdMaster_c, X"0280", 1);
                    pushWrData(net, X"05");
                    -- Blocking
                    expectWrResponse(RespSuccess);
                end if;
            end if;

            if run("SingleWrite-RespError") then
                if ImplWrite_g then
                    -- Slave
                    expect_aw(net, AxiSlave_c, X"0300");
                    expect_w(net, AxiSlave_c, X"05");
                    push_b(net, AxiSlave_c, resp => AxiResp_SlvErr_c);
                    -- Master
                    pushCommand(net, WrCmdMaster_c, X"0300", 1);
                    pushWrData(net, X"05");
                    -- Blocking
                    expectWrResponse(RespError);
                end if;
            end if;

            -- *** Single Reads ***
            if run("SingleRead") then
                if ImplRead_g then

                    -- both latency modes
                    for LowLatency in 0 to 1 loop
                        -- Slave
                        push_single_read (net, AxiSlave_c, X"0200", X"120A");
                        -- Master
                        pushCommand(net, RdCmdMaster_c, X"0200", 1, CmdLowLat => choose(LowLatency=1, '1', '0'));
                        expectRdData(net, X"120A");
                        -- Blocking
                        expectRdResponse(RespSuccess);
                    end loop;

                end if;
            end if;

            if run("SingleRead-DelayedArReady") then
                if ImplRead_g then
                    -- Slave
                    push_single_read (net, AxiSlave_c, X"0280", X"10", ar_ready_delay => 200 ns);
                    -- Master
                    pushCommand(net, RdCmdMaster_c, X"0280", 1);
                    expectRdData(net, X"10");
                    -- Blocking
                    expectRdResponse(RespSuccess);
                end if;
            end if;

            if run("SingleRead-DelayedRValid") then
                if ImplRead_g then
                    -- Slave
                    push_single_read (net, AxiSlave_c, X"0200", X"20", r_valid_delay => 200 ns);
                    -- Master
                    pushCommand(net, RdCmdMaster_c, X"0200", 1);
                    expectRdData(net, X"20");
                    -- Blocking
                    expectRdResponse(RespSuccess);
                end if;
            end if;

            if run("SingleRead-RespError") then
                if ImplRead_g then
                    -- Slave
                    expect_ar(net, AxiSlave_c, X"0300");
                    push_r(net, AxiSlave_c, X"23", error_code => AxiResp_SlvErr_c);
                    -- Master
                    pushCommand(net, RdCmdMaster_c, X"0300", 1);
                    expectRdData(net, X"23");
                    -- Blocking
                    expectRdResponse(RespError);
                end if;
            end if;

            -- *** Burst Writes ***
            if run("BurstWrite") then
                if ImplWrite_g then

                    -- Both latency modes
                    for LowLatency in 0 to 1 loop
                        -- Slave
                        expectAxiWrite(net, X"0100", X"1234", 12);
                        -- Master
                        pushCommand(net, WrCmdMaster_c, X"0100", 12, CmdLowLat => choose(LowLatency=1, '1', '0'));
                        pushWrData(net, X"1234", 1, 12);
                        -- Blocking
                        expectWrResponse(RespSuccess);
                    end loop;

                end if;
            end if;

            if run("BurstWriteOver4kBoundary") then
                if ImplWrite_g then
                    -- 2 words before boundary, 6 after, 8 total
                    -- Slave
                    expectAxiWrite(net, X"1000"-2*AxiDataWidth_g/8, X"1234", 2);
                    expectAxiWrite(net, X"1000", X"1236", 6);
                    -- Master
                    pushCommand(net, WrCmdMaster_c, X"1000"-2*AxiDataWidth_g/8, 8);
                    pushWrData(net, X"1234", 1, 8);
                    -- Blocking
                    expectWrResponse(RespSuccess);
                end if;
            end if;

            if run("BurstWrite-FirstBurstError") then
                if ImplWrite_g and FixedBursts_c then
                    -- 2 words before boundary, 6 after, 8 total
                    -- Slave first burst
                    expect_aw(net, AxiSlave_c, X"2000"-2*AxiDataWidth_g/8, len => 2);
                    expect_w(net, AxiSlave_c, X"12", beats => 2);
                    push_b(net, AxiSlave_c, resp => AxiResp_SlvErr_c);
                    -- Slave second burst
                    expect_burst_write_aligned(net, AxiSlave_c, X"2000", X"14", 1, 6);
                    -- Master
                    pushCommand(net, WrCmdMaster_c, X"2000"-2*AxiDataWidth_g/8, 8);
                    pushWrData(net, X"12", 1, 8);
                    -- Blocking
                    expectWrResponse(RespError);
                end if;
            end if;

            if run("BurstWrite-AllBurstsError") then
                if ImplWrite_g and FixedBursts_c then
                    -- 2 words before boundary, 6 after, 8 total, SLVERR on both bursts
                    -- Slave
                    expect_aw(net, AxiSlave_c, X"6000"-2*AxiDataWidth_g/8, len => 2);
                    expect_w(net, AxiSlave_c, X"12", beats => 2);
                    push_b(net, AxiSlave_c, resp => AxiResp_SlvErr_c);
                    expect_aw(net, AxiSlave_c, X"6000", len => 6);
                    expect_w(net, AxiSlave_c, X"14", beats => 6);
                    push_b(net, AxiSlave_c, resp => AxiResp_SlvErr_c);
                    -- Master
                    pushCommand(net, WrCmdMaster_c, X"6000"-2*AxiDataWidth_g/8, 8);
                    pushWrData(net, X"12", 1, 8);
                    -- Blocking
                    expectWrResponse(RespError);
                    -- The next write without error reports success
                    expect_single_write (net, AxiSlave_c, X"0600", X"34");
                    pushCommand(net, WrCmdMaster_c, X"0600", 1);
                    pushWrData(net, X"34");
                    expectWrResponse(RespSuccess);
                end if;
            end if;

            -- *** Burst Reads ***
            if run("BurstRead") then
                if ImplRead_g then

                    -- Both latency modes
                    for LowLatency in 0 to 1 loop
                        -- Slave
                        pushAxiRead(net, X"0200", X"10EF", 12);
                        -- Master
                        pushCommand(net, RdCmdMaster_c, X"0200", 12, CmdLowLat => choose(LowLatency=1, '1', '0'));
                        expectRdData(net, X"10EF", 1, 12);
                        -- Blocking
                        expectRdResponse(RespSuccess);
                    end loop;

                end if;
            end if;

            if run("BurstReadOver4kBoundary") then
                if ImplRead_g then
                    -- 2 words before boundary, 6 after, 8 total
                    -- Slave
                    pushAxiRead(net, X"2000"-2*AxiDataWidth_g/8, X"09", 2);
                    pushAxiRead(net, X"2000", X"0B", 6);
                    -- Master
                    pushCommand(net, RdCmdMaster_c, X"2000"-2*AxiDataWidth_g/8, 8);
                    expectRdData(net, X"09", 1, 8);
                    -- Blocking
                    expectRdResponse(RespSuccess);
                end if;
            end if;

            if run("BurstRead-FirstBurstError") then
                if ImplRead_g and FixedBursts_c then
                    -- 2 words before boundary, 6 after, 8 total
                    -- Slave first burst
                    expect_ar(net, AxiSlave_c, X"3000"-2*AxiDataWidth_g/8, len => 2);
                    push_r(net, AxiSlave_c, X"12", beats => 2, error_code => AxiResp_SlvErr_c);
                    -- Slave second burst
                    push_burst_read_aligned (net, AxiSlave_c, X"3000", X"14", 1, 6);
                    -- Master
                    pushCommand(net, RdCmdMaster_c, X"3000"-2*AxiDataWidth_g/8, 8);
                    expectRdData(net, X"12", 1, 8);
                    -- Blocking
                    expectRdResponse(RespError);
                end if;
            end if;

            if run("BurstRead-MidBurstError") then
                if ImplRead_g and FixedBursts_c then
                    -- One burst of 4 beats, SLVERR on the second beat only
                    -- Slave
                    expect_ar(net, AxiSlave_c, X"0400", len => 4);
                    push_r(net, AxiSlave_c, X"20", beats => 4, error_code => AxiResp_SlvErr_c, error_beat => 1);
                    -- Master
                    pushCommand(net, RdCmdMaster_c, X"0400", 4);
                    expectRdData(net, X"20", 1, 4);
                    -- Blocking
                    expectRdResponse(RespError);
                end if;
            end if;

            if run("BurstRead-AllBurstsError") then
                if ImplRead_g and FixedBursts_c then
                    -- 2 words before boundary, 6 after, 8 total, SLVERR on both bursts
                    -- Slave
                    expect_ar(net, AxiSlave_c, X"5000"-2*AxiDataWidth_g/8, len => 2);
                    push_r(net, AxiSlave_c, X"12", beats => 2, error_code => AxiResp_SlvErr_c);
                    expect_ar(net, AxiSlave_c, X"5000", len => 6);
                    push_r(net, AxiSlave_c, X"14", beats => 6, error_code => AxiResp_SlvErr_c);
                    -- Master
                    pushCommand(net, RdCmdMaster_c, X"5000"-2*AxiDataWidth_g/8, 8);
                    expectRdData(net, X"12", 1, 8);
                    -- Blocking
                    expectRdResponse(RespError);
                    -- The next read without error reports success
                    push_single_read (net, AxiSlave_c, X"0500", X"34");
                    pushCommand(net, RdCmdMaster_c, X"0500", 1);
                    expectRdData(net, X"34");
                    expectRdResponse(RespSuccess);
                end if;
            end if;

            -- *** Check if high-latency read command with full FIFO is delayed ***
            if run("BurstRead-FifoFull") then
                if ImplRead_g and FixedBursts_c then

                    -- both latency modes
                    for LowLatency in 0 to 1 loop
                        -- Fill FIFO
                        pushCommand(net, RdCmdMaster_c, X"4000", DataFifoDepth_c, CmdLowLat => choose(LowLatency=1, '1', '0'));
                        wait for 100 ns;
                        check_equal(AxiMs.ar_valid, '1', "Fill Command not Valid");
                        push_burst_read_aligned (net, AxiSlave_c, X"4000", X"10", 1, DataFifoDepth_c);
                        wait for 200 ns;
                        -- Push Second Command with full FIFO
                        pushCommand(net, RdCmdMaster_c, X"5000", 4, CmdLowLat => choose(LowLatency=1, '1', '0'));
                        wait for 200 ns;
                        if LowLatency = 0 then
                            check_equal(AxiMs.ar_valid, '0', "Second Command Valid despite full FIFO");
                        else
                            check_equal(AxiMs.ar_valid, '1', "Second Command not Valid despite low-latency");
                        end if;
                        -- Execute both commands
                        expectRdData(net, X"10", 1, DataFifoDepth_c);
                        push_burst_read_aligned (net, AxiSlave_c, X"5000", X"40", 1, 4);
                        expectRdData(net, X"40", 1, 4);
                        wait_until_idle(net, as_sync(RdDataSlave_c));
                    end loop;

                end if;
            end if;

            -- *** Test handshake on Data Lane ***
            if run("BurstRead-SlowData") then
                if ImplRead_g then
                    -- Slave
                    pushAxiRead(net, X"0200", X"10EF", 12, beatDelay => 50 ns);
                    -- Master
                    pushCommand(net, RdCmdMaster_c, X"0200", 12, CmdLowLat => '0');
                    expectRdData(net, X"10EF", 1, 12);
                    -- Blocking
                    expectRdResponse(RespSuccess);
                end if;
            end if;

            if run("BurstWrite-SlowData") then
                if ImplWrite_g then
                    -- Slave
                    expectAxiWrite(net, X"0100", X"1234", 12, beatDelay => 50 ns);
                    -- Master
                    pushCommand(net, WrCmdMaster_c, X"0100", 12, CmdLowLat => '0');
                    pushWrData(net, X"1234", 1, 12);
                    -- Blocking
                    expectWrResponse(RespSuccess);
                end if;
            end if;

            -- *** Split Transfers at Maximum Transaction Size ***
            if run("BurstRead-MaxTransactionSize") then
                if ImplRead_g then
                    -- Slave
                    pushAxiRead(net, X"0200", X"10EF", MaxTfBeats_c);
                    -- Master
                    pushCommand(net, RdCmdMaster_c, X"0200", MaxTfBeats_c, CmdLowLat => '1'); -- must be lowlatency becuause larger than FIFO
                    expectRdData(net, X"10EF", 1, MaxTfBeats_c);
                    -- Blocking
                    expectRdResponse(RespSuccess);
                end if;
            end if;

            if run("BurstWrite-MaxTransactionSize") then
                if ImplWrite_g then
                    -- Slave
                    expectAxiWrite(net, X"0100", X"1234", MaxTfBeats_c);
                    -- Master
                    pushCommand(net, WrCmdMaster_c, X"0100", MaxTfBeats_c, CmdLowLat => '1'); -- must be lowlatency becuause larger than FIFO
                    pushWrData(net, X"1234", 1, MaxTfBeats_c);
                    -- Blocking
                    expectWrResponse(RespSuccess);
                end if;
            end if;

            -- *** Response codes ***
            if run("SingleWrite-DecErr") then
                if ImplWrite_g then
                    -- Slave
                    expect_aw(net, AxiSlave_c, X"0700");
                    expect_w(net, AxiSlave_c, X"06");
                    push_b(net, AxiSlave_c, resp => AxiResp_DecErr_c);
                    -- Master
                    pushCommand(net, WrCmdMaster_c, X"0700", 1);
                    pushWrData(net, X"06");
                    -- Blocking
                    expectWrResponse(RespError, AxiResp_DecErr_c);
                end if;
            end if;

            if run("SingleRead-DecErr") then
                if ImplRead_g then
                    -- Slave
                    expect_ar(net, AxiSlave_c, X"0700");
                    push_r(net, AxiSlave_c, X"24", error_code => AxiResp_DecErr_c);
                    -- Master
                    pushCommand(net, RdCmdMaster_c, X"0700", 1);
                    expectRdData(net, X"24");
                    -- Blocking
                    expectRdResponse(RespError, AxiResp_DecErr_c);
                end if;
            end if;

            -- The masters never request exclusive access: EXOKAY is a failure
            if run("SingleRead-ExOkay") then
                if ImplRead_g then
                    -- Slave
                    expect_ar(net, AxiSlave_c, X"0800");
                    push_r(net, AxiSlave_c, X"25", error_code => AxiResp_ExOkay_c);
                    -- Master
                    pushCommand(net, RdCmdMaster_c, X"0800", 1);
                    expectRdData(net, X"25");
                    -- Blocking
                    expectRdResponse(RespError, AxiResp_ExOkay_c);
                end if;
            end if;

            if run("BurstWrite-FirstBurstDecErr") then
                if ImplWrite_g and FixedBursts_c then
                    -- 2 words before boundary, 6 after, 8 total, DECERR on the first burst
                    -- Slave first burst
                    expect_aw(net, AxiSlave_c, X"7000"-2*AxiDataWidth_g/8, len => 2);
                    expect_w(net, AxiSlave_c, X"12", beats => 2);
                    push_b(net, AxiSlave_c, resp => AxiResp_DecErr_c);
                    -- Slave second burst
                    expect_burst_write_aligned(net, AxiSlave_c, X"7000", X"14", 1, 6);
                    -- Master
                    pushCommand(net, WrCmdMaster_c, X"7000"-2*AxiDataWidth_g/8, 8);
                    pushWrData(net, X"12", 1, 8);
                    -- Blocking
                    expectWrResponse(RespError, AxiResp_DecErr_c);
                end if;
            end if;

            if run("BurstWrite-TwoErrors") then
                if ImplWrite_g and FixedBursts_c then
                    -- DECERR on the first burst, SLVERR on the second: the first one is reported
                    -- Slave
                    expect_aw(net, AxiSlave_c, X"9000"-2*AxiDataWidth_g/8, len => 2);
                    expect_w(net, AxiSlave_c, X"12", beats => 2);
                    push_b(net, AxiSlave_c, resp => AxiResp_DecErr_c);
                    expect_aw(net, AxiSlave_c, X"9000", len => 6);
                    expect_w(net, AxiSlave_c, X"14", beats => 6);
                    push_b(net, AxiSlave_c, resp => AxiResp_SlvErr_c);
                    -- Master
                    pushCommand(net, WrCmdMaster_c, X"9000"-2*AxiDataWidth_g/8, 8);
                    pushWrData(net, X"12", 1, 8);
                    -- Blocking
                    expectWrResponse(RespError, AxiResp_DecErr_c);
                    -- The next write without error reports success and no code
                    expect_single_write (net, AxiSlave_c, X"0900", X"35");
                    pushCommand(net, WrCmdMaster_c, X"0900", 1);
                    pushWrData(net, X"35");
                    expectWrResponse(RespSuccess);
                end if;
            end if;

            if run("BurstRead-MidBurstDecErr") then
                if ImplRead_g and FixedBursts_c then
                    -- One burst of 4 beats, DECERR on the second beat only
                    -- Slave
                    expect_ar(net, AxiSlave_c, X"0A00", len => 4);
                    push_r(net, AxiSlave_c, X"20", beats => 4, error_code => AxiResp_DecErr_c, error_beat => 1);
                    -- Master
                    pushCommand(net, RdCmdMaster_c, X"0A00", 4);
                    expectRdData(net, X"20", 1, 4);
                    -- Blocking
                    expectRdResponse(RespError, AxiResp_DecErr_c);
                end if;
            end if;

            if run("BurstRead-TwoErrors") then
                if ImplRead_g and FixedBursts_c then
                    -- DECERR on the first beat of the first burst, SLVERR on all beats of the second: the first one
                    -- is reported
                    -- Slave
                    expect_ar(net, AxiSlave_c, X"B000"-2*AxiDataWidth_g/8, len => 2);
                    push_r(net, AxiSlave_c, X"12", beats => 2, error_code => AxiResp_DecErr_c, error_beat => 0);
                    expect_ar(net, AxiSlave_c, X"B000", len => 6);
                    push_r(net, AxiSlave_c, X"14", beats => 6, error_code => AxiResp_SlvErr_c);
                    -- Master
                    pushCommand(net, RdCmdMaster_c, X"B000"-2*AxiDataWidth_g/8, 8);
                    expectRdData(net, X"12", 1, 8);
                    -- Blocking
                    expectRdResponse(RespError, AxiResp_DecErr_c);
                    -- The next read without error reports success and no code
                    push_single_read (net, AxiSlave_c, X"0B00", X"36");
                    pushCommand(net, RdCmdMaster_c, X"0B00", 1);
                    expectRdData(net, X"36");
                    expectRdResponse(RespSuccess);
                end if;
            end if;

            -- *** FIXED Bursts ***
            -- Bursts of at most FixedMaxBeats_c beats, all at the command address
            if run("FixedWrite") then
                if ImplWrite_g then

                    -- Both latency modes
                    for LowLatency in 0 to 1 loop

                        for i in FixedSizes_c'range loop
                            -- Slave
                            expectAxiWrite(net, X"0300"+256*i, X"5A00"+1024*i, FixedSizes_c(i), fixed => true);
                            -- Master
                            pushCommand(net, WrCmdMaster_c, X"0300"+256*i, FixedSizes_c(i),
                                        CmdLowLat => choose(LowLatency=1, '1', '0'), CmdFixed => '1');
                            pushWrData(net, X"5A00"+1024*i, 1, FixedSizes_c(i));
                            -- Blocking
                            expectWrResponse(RespSuccess);
                        end loop;

                    end loop;

                end if;
            end if;

            if run("FixedRead") then
                if ImplRead_g then

                    -- Both latency modes
                    for LowLatency in 0 to 1 loop

                        for i in FixedSizes_c'range loop
                            -- Slave
                            pushAxiRead(net, X"0300"+256*i, X"6B00"+1024*i, FixedSizes_c(i), fixed => true);
                            -- Master
                            pushCommand(net, RdCmdMaster_c, X"0300"+256*i, FixedSizes_c(i),
                                        CmdLowLat => choose(LowLatency=1, '1', '0'), CmdFixed => '1');
                            expectRdData(net, X"6B00"+1024*i, 1, FixedSizes_c(i));
                            -- Blocking
                            expectRdResponse(RespSuccess);
                        end loop;

                    end loop;

                end if;
            end if;

            -- A FIXED burst accesses one address: no split at a 4 KB boundary
            if run("FixedWriteAt4kBoundary") then
                if ImplWrite_g then
                    -- 2 words before the boundary, 8 beats
                    expectAxiWrite(net, X"1000"-2*AxiDataWidth_g/8, X"1234", 8, fixed => true);
                    pushCommand(net, WrCmdMaster_c, X"1000"-2*AxiDataWidth_g/8, 8, CmdFixed => '1');
                    pushWrData(net, X"1234", 1, 8);
                    expectWrResponse(RespSuccess);
                end if;
            end if;

            if run("FixedReadAt4kBoundary") then
                if ImplRead_g then
                    -- 2 words before the boundary, 8 beats
                    pushAxiRead(net, X"2000"-2*AxiDataWidth_g/8, X"09", 8, fixed => true);
                    pushCommand(net, RdCmdMaster_c, X"2000"-2*AxiDataWidth_g/8, 8, CmdFixed => '1');
                    expectRdData(net, X"09", 1, 8);
                    expectRdResponse(RespSuccess);
                end if;
            end if;

            -- INCR, FIXED, INCR back to back with outstanding transactions: the burst type belongs to its address
            if run("FixedIncr-BackToBack-Write") then
                if ImplWrite_g then
                    -- Slave
                    expectAxiWrite(net, X"1000"-2*AxiDataWidth_g/8, X"0100", 8);
                    expectAxiWrite(net, X"2000"-2*AxiDataWidth_g/8, X"0200", 20, fixed => true);
                    expectAxiWrite(net, X"3000"-2*AxiDataWidth_g/8, X"0300", 12);
                    -- Master
                    pushCommand(net, WrCmdMaster_c, X"1000"-2*AxiDataWidth_g/8, 8, CmdLowLat => '1');
                    pushCommand(net, WrCmdMaster_c, X"2000"-2*AxiDataWidth_g/8, 20, CmdLowLat => '1', CmdFixed => '1');
                    pushCommand(net, WrCmdMaster_c, X"3000"-2*AxiDataWidth_g/8, 12, CmdLowLat => '1');
                    pushWrData(net, X"0100", 1, 8);
                    pushWrData(net, X"0200", 1, 20);
                    pushWrData(net, X"0300", 1, 12);
                    -- Blocking
                    expectWrResponse(RespSuccess);
                    expectWrResponse(RespSuccess);
                    expectWrResponse(RespSuccess);
                end if;
            end if;

            if run("FixedIncr-BackToBack-Read") then
                if ImplRead_g then
                    -- Slave
                    pushAxiRead(net, X"1000"-2*AxiDataWidth_g/8, X"0100", 8);
                    pushAxiRead(net, X"2000"-2*AxiDataWidth_g/8, X"0200", 20, fixed => true);
                    pushAxiRead(net, X"3000"-2*AxiDataWidth_g/8, X"0300", 12);
                    -- Master
                    pushCommand(net, RdCmdMaster_c, X"1000"-2*AxiDataWidth_g/8, 8);
                    pushCommand(net, RdCmdMaster_c, X"2000"-2*AxiDataWidth_g/8, 20, CmdFixed => '1');
                    pushCommand(net, RdCmdMaster_c, X"3000"-2*AxiDataWidth_g/8, 12);
                    expectRdData(net, X"0100", 1, 8);
                    expectRdData(net, X"0200", 1, 20);
                    expectRdData(net, X"0300", 1, 12);
                    -- Blocking
                    expectRdResponse(RespSuccess);
                    expectRdResponse(RespSuccess);
                    expectRdResponse(RespSuccess);
                end if;
            end if;

            -- Error response of a FIXED burst
            if run("FixedWrite-RespError") then
                if ImplWrite_g then
                    -- Slave
                    expect_aw(net, AxiSlave_c, X"0600", len => FixedMaxBeats_c, burst => AxiBurst_Fixed_c);
                    expect_w(net, AxiSlave_c, X"40", 1, FixedMaxBeats_c);
                    push_b(net, AxiSlave_c, resp => AxiResp_SlvErr_c);
                    -- Master
                    pushCommand(net, WrCmdMaster_c, X"0600", FixedMaxBeats_c, CmdFixed => '1');
                    pushWrData(net, X"40", 1, FixedMaxBeats_c);
                    -- Blocking
                    expectWrResponse(RespError, AxiResp_SlvErr_c);
                end if;
            end if;

            if run("FixedRead-RespError") then
                if ImplRead_g then
                    -- Slave
                    expect_ar(net, AxiSlave_c, X"0600", len => FixedMaxBeats_c, burst => AxiBurst_Fixed_c);
                    push_r(net, AxiSlave_c, X"40", beats => FixedMaxBeats_c, error_code => AxiResp_SlvErr_c);
                    -- Master
                    pushCommand(net, RdCmdMaster_c, X"0600", FixedMaxBeats_c, CmdFixed => '1');
                    expectRdData(net, X"40", 1, FixedMaxBeats_c);
                    -- Blocking
                    expectRdResponse(RespError, AxiResp_SlvErr_c);
                end if;
            end if;

            -- Wait for idle
            wait_until_idle(net, as_sync(AxiSlave_c));
            wait_until_idle(net, as_sync(RdDataSlave_c));
            wait_until_idle(net, as_sync(WrCmdMaster_c));
            wait_until_idle(net, as_sync(RdCmdMaster_c));
            wait_until_idle(net, as_sync(WrDataMaster_c));
            wait for 1 us;

        end loop;

        -- TB done
        test_runner_cleanup(runner);
    end process;

    -----------------------------------------------------------------------------------------------
    -- Response code checker: "00" outside the error pulses (after the first reset)
    -----------------------------------------------------------------------------------------------
    p_errresp : process (Clk) is
        variable WasReset_v : boolean := false;
    begin
        if rising_edge(Clk) then
            if Rst = '1' then
                WasReset_v := true;
            elsif WasReset_v then
                if ImplWrite_g and Wr_Error /= '1' then
                    check_equal(Wr_ErrorResp, AxiResp_Okay_c, "Wr_ErrorResp outside Wr_Error");
                end if;
                if ImplRead_g and Rd_Error /= '1' then
                    check_equal(Rd_ErrorResp, AxiResp_Okay_c, "Rd_ErrorResp outside Rd_Error");
                end if;
            end if;
        end if;
    end process;

    -----------------------------------------------------------------------------------------------
    -- Clock
    -----------------------------------------------------------------------------------------------
    Clk <= not Clk after 0.5*Clk_Period_c;

    -----------------------------------------------------------------------------------------------
    -- DUT
    -----------------------------------------------------------------------------------------------
    i_dut : entity olo.olo_axi_master_simple
        generic map (
            AxiAddrWidth_g              => AxiAddrWidth_g,
            AxiDataWidth_g              => AxiDataWidth_g,
            AxiMaxBeats_g               => AxiMaxBeats_g,
            AxiMaxOpenTransactions_g    => AxiMaxOpenTransactions_g,
            -- User Configuration
            UserTransactionSizeBits_g   => UserTransactionSizeBits_c,
            DataFifoDepth_g             => DataFifoDepth_c,
            ImplRead_g                  => ImplRead_g,
            ImplWrite_g                 => ImplWrite_g,
            RamBehavior_g               => RamBehavior_g
        )
        port map (
            -- Control Signals
            Clk            => Clk,
            Rst            => Rst,
            -- User Command Interface
            CmdWr_Addr     => CmdWr_Addr,
            CmdWr_Size     => CmdWr_Size,
            CmdWr_LowLat   => CmdWr_LowLat,
            CmdWr_Fixed    => CmdWr_Fixed,
            CmdWr_Valid    => CmdWr_Valid,
            CmdWr_Ready    => CmdWr_Ready,
            -- User Command Interface
            CmdRd_Addr     => CmdRd_Addr,
            CmdRd_Size     => CmdRd_Size,
            CmdRd_LowLat   => CmdRd_LowLat,
            CmdRd_Fixed    => CmdRd_Fixed,
            CmdRd_Valid    => CmdRd_Valid,
            CmdRd_Ready    => CmdRd_Ready,
            -- Write Data
            Wr_Data        => Wr_Data,
            Wr_Be          => Wr_Be,
            Wr_Valid       => Wr_Valid,
            Wr_Ready       => Wr_Ready,
            -- Read Data
            Rd_Data        => Rd_Data,
            Rd_Valid       => Rd_Valid,
            Rd_Ready       => Rd_Ready,
            Rd_Last        => Rd_Last,
            -- Response
            Wr_Done        => Wr_Done,
            Wr_Error       => Wr_Error,
            Wr_ErrorResp   => Wr_ErrorResp,
            Rd_Done        => Rd_Done,
            Rd_Error       => Rd_Error,
            Rd_ErrorResp   => Rd_ErrorResp,
            -- AXI Address Write Channel
            M_Axi_AwAddr   => AxiMs.aw_addr,
            M_Axi_AwValid  => AxiMs.aw_valid,
            M_Axi_AwReady  => AxiSm.aw_ready,
            M_Axi_AwLen    => AxiMs.aw_len,
            M_Axi_AwSize   => AxiMs.aw_size,
            M_Axi_AwBurst  => AxiMs.aw_burst,
            M_Axi_AwLock   => AxiMs.aw_lock,
            M_Axi_AwCache  => AxiMs.aw_cache,
            M_Axi_AwProt   => AxiMs.aw_prot,
            -- AXI Write Data Channel
            M_Axi_WData    => AxiMs.w_data,
            M_Axi_WStrb    => AxiMs.w_strb,
            M_Axi_WValid   => AxiMs.w_valid,
            M_Axi_WReady   => AxiSm.w_ready,
            M_Axi_WLast    => AxiMs.w_last,
            -- AXI Write Response Channel
            M_Axi_BResp    => AxiSm.b_resp,
            M_Axi_BValid   => AxiSm.b_valid,
            M_Axi_BReady   => AxiMs.b_ready,
            -- AXI Read Address Channel
            M_Axi_ArAddr   => AxiMs.ar_addr,
            M_Axi_ArValid  => AxiMs.ar_valid,
            M_Axi_ArReady  => AxiSm.ar_ready,
            M_Axi_ArLen    => AxiMs.ar_len,
            M_Axi_ArSize   => AxiMs.ar_size,
            M_Axi_ArBurst  => AxiMs.ar_burst,
            M_Axi_ArLock   => AxiMs.ar_lock,
            M_Axi_ArCache  => AxiMs.ar_cache,
            M_Axi_ArProt   => AxiMs.ar_prot,
            -- AXI Read Data Channel
            M_Axi_RData    => AxiSm.r_data,
            M_Axi_RValid   => AxiSm.r_valid,
            M_Axi_RReady   => AxiMs.r_ready,
            M_Axi_RResp    => AxiSm.r_resp,
            M_Axi_RLast    => AxiSm.r_last
        );

    -----------------------------------------------------------------------------------------------
    -- Verification Components
    -----------------------------------------------------------------------------------------------
    vc_slave : entity work.olo_test_axi_slave_vc
        generic map (
            Instance => AxiSlave_c
        )
        port map (
            Clk    => Clk,
            Axi_Ms => AxiMs,
            Axi_Sm => AxiSm
        );

    vc_rd_data : entity vunit_lib.axi_stream_slave
        generic map (
            Slave => RdDataSlave_c
        )
        port map (
            AClk   => Clk,
            TValid => Rd_Valid,
            TReady => Rd_Ready,
            TData  => Rd_Data,
            TLast  => Rd_Last
        );

    b_wr_cmd : block is
        signal TDataLocal : std_logic_vector(CmdFixed_c downto 0);
    begin

        vc_wr_cmd : entity vunit_lib.axi_stream_master
            generic map (
                Master => WrCmdMaster_c
            )
            port map (
                AClk   => Clk,
                TValid => CmdWr_Valid,
                TReady => CmdWr_Ready,
                TData  => TDataLocal
            );

        CmdWr_Addr   <= TDataLocal(CmdAddrRange_c);
        CmdWr_Size   <= TDataLocal(CmdSizeRange_c);
        CmdWr_LowLat <= TDataLocal(CmdLowLat_c);
        CmdWr_Fixed  <= TDataLocal(CmdFixed_c);
    end block;

    b_rd_cmd : block is
        signal TDataLocal : std_logic_vector(CmdFixed_c downto 0);
    begin

        vc_rd_cmd : entity vunit_lib.axi_stream_master
            generic map (
                Master => RdCmdMaster_c
            )
            port map (
                AClk   => Clk,
                TValid => CmdRd_Valid,
                TReady => CmdRd_Ready,
                TData  => TDataLocal
            );

        CmdRd_Addr   <= TDataLocal(CmdAddrRange_c);
        CmdRd_Size   <= TDataLocal(CmdSizeRange_c);
        CmdRd_LowLat <= TDataLocal(CmdLowLat_c);
        CmdRd_Fixed  <= TDataLocal(CmdFixed_c);
    end block;

    b_wr_data : block is
        signal TDataLocal : std_logic_vector(DatBeRange_c'high downto 0);
    begin

        vc_wr_data : entity vunit_lib.axi_stream_master
            generic map (
                Master => WrDataMaster_c
            )
            port map (
                AClk   => Clk,
                TValid => Wr_Valid,
                TReady => Wr_Ready,
                TData  => TDataLocal
            );

        Wr_Data <= TDataLocal(DatDataRange_c);
        Wr_Be   <= TDataLocal(DatBeRange_c);
    end block;

end architecture;
