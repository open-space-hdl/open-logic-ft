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

library work;
    use work.olo_test_pkg_axi.all;
    use work.olo_test_axi_slave_pkg.all;
    use work.olo_test_ft_pkg.all;

library olo;
    use olo.olo_base_pkg_math.all;
    use olo.olo_base_pkg_logic.all;
    use olo.olo_ft_pkg_ecc.all;

---------------------------------------------------------------------------------------------------
-- Entity
---------------------------------------------------------------------------------------------------
-- vunit: run_all_in_same_sim
entity olo_ft_axi_master_simple_tb is
    generic (
        runner_cfg     : string;
        AxiDataWidth_g : natural range 16 to 64 := 32;
        ImplRead_g     : boolean                := true;
        ImplWrite_g    : boolean                := true
    );
end entity;

architecture sim of olo_ft_axi_master_simple_tb is

    -----------------------------------------------------------------------------------------------
    -- Fixed Generics
    -----------------------------------------------------------------------------------------------
    constant AxiAddrWidth_c            : natural := 32;
    constant UserTransactionSizeBits_c : natural := 10;
    constant AxiMaxBeats_c             : natural := 16;
    constant AxiMaxOpenTransactions_c  : natural := 2;
    constant DataFifoDepth_c           : natural := 64;

    -----------------------------------------------------------------------------------------------
    -- AXI Definition
    -----------------------------------------------------------------------------------------------
    constant ByteWidth_c : integer := AxiDataWidth_g / 8;

    subtype IdRange_c   is natural range -1 downto 0;
    subtype AddrRange_c is natural range AxiAddrWidth_c - 1 downto 0;
    subtype UserRange_c is natural range 1 downto 0;
    subtype DataRange_c is natural range AxiDataWidth_g - 1 downto 0;
    subtype ByteRange_c is natural range ByteWidth_c - 1 downto 0;

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
    constant WrBufWidth_c    : natural := AxiDataWidth_g + AxiDataWidth_g / 8;
    constant RdBufWidth_c    : natural := AxiDataWidth_g + 1;
    constant WrCodewordWid_c : natural := eccCodewordWidth(WrBufWidth_c);
    constant RdCodewordWid_c : natural := eccCodewordWidth(RdBufWidth_c);

    subtype CmdAddrRange_c is natural range AxiAddrWidth_c - 1 downto 0;
    subtype CmdSizeRange_c is natural range UserTransactionSizeBits_c + CmdAddrRange_c'high downto CmdAddrRange_c'high + 1;
    constant CmdLowLat_c : natural := CmdSizeRange_c'high + 1;

    subtype DatDataRange_c is natural range AxiDataWidth_g - 1 downto 0;
    subtype DatBeRange_c is natural range AxiDataWidth_g / 8 + DatDataRange_c'high downto DatDataRange_c'high + 1;

    -----------------------------------------------------------------------------------------------
    -- TB Definitions
    -----------------------------------------------------------------------------------------------
    constant Clk_Frequency_c : real := 100.0e6;
    constant Clk_Period_c    : time := (1 sec) / Clk_Frequency_c;

    type Response_t is (RespSuccess, RespError);

    -----------------------------------------------------------------------------------------------
    -- Interface Signals
    -----------------------------------------------------------------------------------------------
    signal Clk               : std_logic                                                := '0';
    signal Rst               : std_logic                                                := '0';
    signal CmdWr_Addr        : std_logic_vector(AxiAddrWidth_c - 1 downto 0)            := (others => '0');
    signal CmdWr_Size        : std_logic_vector(UserTransactionSizeBits_c - 1 downto 0) := (others => '0');
    signal CmdWr_LowLat      : std_logic                                                := '0';
    signal CmdWr_Valid       : std_logic                                                := '0';
    signal CmdWr_Ready       : std_logic;
    signal CmdRd_Addr        : std_logic_vector(AxiAddrWidth_c - 1 downto 0)            := (others => '0');
    signal CmdRd_Size        : std_logic_vector(UserTransactionSizeBits_c - 1 downto 0) := (others => '0');
    signal CmdRd_LowLat      : std_logic                                                := '0';
    signal CmdRd_Valid       : std_logic                                                := '0';
    signal CmdRd_Ready       : std_logic;
    signal Wr_Data           : std_logic_vector(AxiDataWidth_g - 1 downto 0)            := (others => '0');
    signal Wr_Be             : std_logic_vector(AxiDataWidth_g / 8 - 1 downto 0)        := (others => '0');
    signal Wr_Valid          : std_logic                                                := '0';
    signal Wr_Ready          : std_logic;
    signal Wr_EccSec         : std_logic;
    signal Wr_EccDed         : std_logic;
    signal Rd_Data           : std_logic_vector(AxiDataWidth_g - 1 downto 0);
    signal Rd_Last           : std_logic;
    signal Rd_Valid          : std_logic;
    signal Rd_Ready          : std_logic                                                := '0';
    signal Rd_EccSec         : std_logic;
    signal Rd_EccDed         : std_logic;
    signal Rd_TUser          : std_logic_vector(1 downto 0);
    signal Wr_Done           : std_logic;
    signal Wr_Error          : std_logic;
    signal Rd_Done           : std_logic;
    signal Rd_Error          : std_logic;
    signal Wr_ErrInj_BitFlip : std_logic_vector(WrCodewordWid_c - 1 downto 0)           := (others => '0');
    signal Wr_ErrInj_Valid   : std_logic                                                := '0';
    signal Rd_ErrInj_BitFlip : std_logic_vector(RdCodewordWid_c - 1 downto 0)           := (others => '0');
    signal Rd_ErrInj_Valid   : std_logic                                                := '0';

    -- Write-flag pulse counters (Wr_EccSec/Wr_EccDed are one-cycle pulses)
    signal CntClr   : std_logic := '0';
    signal WrSecCnt : natural   := 0;
    signal WrDedCnt : natural   := 0;

    -----------------------------------------------------------------------------------------------
    -- Verification Components
    -----------------------------------------------------------------------------------------------
    constant AxiSlave_c : olo_test_axi_slave_t := new_olo_test_axi_slave (
        data_width => AxiDataWidth_g,
        addr_width => AxiAddrWidth_c,
        id_width => 0
    );

    constant RdDataSlave_c : axi_stream_slave_t := new_axi_stream_slave (
        data_length  => AxiDataWidth_g,
        user_length  => 2,
        stall_config => new_stall_config(0.0, 0, 0)
    );

    constant WrCmdMaster_c : axi_stream_master_t := new_axi_stream_master (
        data_length  => AxiAddrWidth_c + UserTransactionSizeBits_c + 1,
        stall_config => new_stall_config(0.0, 0, 0)
    );

    constant RdCmdMaster_c : axi_stream_master_t := new_axi_stream_master (
        data_length  => AxiAddrWidth_c + UserTransactionSizeBits_c + 1,
        stall_config => new_stall_config(0.0, 0, 0)
    );

    constant WrDataMaster_c : axi_stream_master_t := new_axi_stream_master (
        data_length  => AxiDataWidth_g + AxiDataWidth_g / 8,
        stall_config => new_stall_config(0.0, 0, 0)
    );

    procedure pushCommand (
        signal net : inout network_t;
        CmdMaster  : axi_stream_master_t;
        CmdAddr    : unsigned;
        CmdSize    : integer;
        CmdLowLat  : std_logic := '0') is
        variable TData_v : std_logic_vector(CmdLowLat_c downto 0);
    begin
        TData_v(CmdAddrRange_c) := std_logic_vector(resize(CmdAddr, AxiAddrWidth_c));
        TData_v(CmdSizeRange_c) := toUslv(CmdSize, UserTransactionSizeBits_c);
        TData_v(CmdLowLat_c)    := CmdLowLat;
        push_axi_stream(net, CmdMaster, TData_v);
    end procedure;

    procedure pushWrData (
        signal net : inout network_t;
        startValue : unsigned;
        increment  : natural := 1;
        beats      : natural := 1) is
        variable TData_v : std_logic_vector(DatBeRange_c'high downto 0);
        variable Data_v  : unsigned(AxiDataWidth_g - 1 downto 0);
    begin
        Data_v := resize(startValue, AxiDataWidth_g);

        for i in 0 to beats - 1 loop
            TData_v(DatDataRange_c) := std_logic_vector(Data_v);
            TData_v(DatBeRange_c)   := (others => '1');
            push_axi_stream(net, WrDataMaster_c, TData_v);
            Data_v                  := Data_v + increment;
        end loop;

    end procedure;

    -- Queue expectations for clean read data (flags must be zero)
    procedure expectRdData (
        signal net : inout network_t;
        startValue : unsigned;
        increment  : natural := 1;
        beats      : natural := 1) is
        variable Data_v : unsigned(AxiDataWidth_g - 1 downto 0);
        variable Last_v : std_logic := '0';
    begin
        Data_v := resize(startValue, AxiDataWidth_g);

        for i in 0 to beats - 1 loop

            if i = beats - 1 then
                Last_v := '1';
            end if;

            check_axi_stream(net, RdDataSlave_c, std_logic_vector(Data_v), blocking => false,
                tlast                                                               => Last_v, tuser => "00",
                msg                                                                 => "RdData " & integer'image(i));
            Data_v := Data_v + increment;
        end loop;

    end procedure;

    -- Queue the expectation for one read beat that was stored with a flip pattern: the decoder
    -- outcome for the {Last, Data} bundle is computed and checked including the flags.
    procedure expectRdBeatFlipped (
        signal net : inout network_t;
        data       : std_logic_vector;
        last       : std_logic;
        flip       : std_logic_vector;
        msg        : string) is
        variable Bundle_v : std_logic_vector(RdBufWidth_c - 1 downto 0);
        variable Dec_v    : std_logic_vector(RdBufWidth_c - 1 downto 0);
        variable ExpSec_v : std_logic;
        variable ExpDed_v : std_logic;
    begin
        Bundle_v := last & data;
        ftExpectedBeat(Bundle_v, flip, Dec_v, ExpSec_v, ExpDed_v);
        check_axi_stream(net, RdDataSlave_c, Dec_v(AxiDataWidth_g - 1 downto 0), blocking => false,
            tlast                                                                         => Dec_v(AxiDataWidth_g),
            tuser                                                                         => ExpSec_v & ExpDed_v, msg => msg);
    end procedure;

    procedure expectWrResponse (Response : Response_t) is
    begin
        wait until rising_edge(Clk) and ((Wr_Done = '1') or (Wr_Error = '1'));

        if Response = RespSuccess then
            check_equal(Wr_Error, '0', "Wrong Wr_Error");
            check_equal(Wr_Done, '1', "Wrong Wr_Done");
        else
            check_equal(Wr_Error, '1', "Wrong Wr_Error");
            check_equal(Wr_Done, '0', "Wrong Wr_Done");
        end if;

    end procedure;

    procedure expectRdResponse (Response : Response_t) is
    begin
        wait until rising_edge(Clk) and ((Rd_Done = '1') or (Rd_Error = '1'));

        if Response = RespSuccess then
            check_equal(Rd_Error, '0', "Wrong Rd_Error");
            check_equal(Rd_Done, '1', "Wrong Rd_Done");
        else
            check_equal(Rd_Error, '1', "Wrong Rd_Error");
            check_equal(Rd_Done, '0', "Wrong Rd_Done");
        end if;

    end procedure;

begin

    -----------------------------------------------------------------------------------------------
    -- TB Control
    -----------------------------------------------------------------------------------------------
    test_runner_watchdog(runner, 5 ms);

    p_control : process is
        variable Flip_v   : std_logic_vector(WrCodewordWid_c - 1 downto 0);
        variable RdFlip_v : std_logic_vector(RdCodewordWid_c - 1 downto 0);
        variable Bundle_v : std_logic_vector(WrBufWidth_c - 1 downto 0);
        variable Dec_v    : std_logic_vector(WrBufWidth_c - 1 downto 0);
        variable Sec_v    : std_logic;
        variable Ded_v    : std_logic;
    begin
        test_runner_setup(runner, runner_cfg);

        while test_suite loop

            -- Reset
            wait until rising_edge(Clk);
            Rst    <= '1';
            CntClr <= '1';
            wait for 1 us;
            wait until rising_edge(Clk);
            Rst    <= '0';
            CntClr <= '0';
            wait until rising_edge(Clk);

            ---------------------------------------------------------------------------------------
            if run("ResetValues") then

                if ImplRead_g then
                    check_equal(Rd_Valid, '0', "Rd_Valid");
                    check_equal(Rd_Done, '0', "Rd_Done");
                    check_equal(Rd_Error, '0', "Rd_Error");
                end if;

                if ImplWrite_g then
                    check_equal(Wr_Done, '0', "Wr_Done");
                    check_equal(Wr_Error, '0', "Wr_Error");
                    check_equal(Wr_EccSec, '0', "Wr_EccSec");
                    check_equal(Wr_EccDed, '0', "Wr_EccDed");
                end if;

            ---------------------------------------------------------------------------------------
            elsif run("SingleWrite") then

                if ImplWrite_g then
                    pushCommand(net, WrCmdMaster_c, x"00001080", 1);
                    pushWrData(net, x"ABCD");
                    expect_single_write(net, AxiSlave_c, x"1080", x"ABCD");
                    expectWrResponse(RespSuccess);
                    check_equal(WrSecCnt, 0, "WrSecCnt");
                    check_equal(WrDedCnt, 0, "WrDedCnt");
                end if;

            ---------------------------------------------------------------------------------------
            elsif run("SingleRead") then

                if ImplRead_g then
                    pushCommand(net, RdCmdMaster_c, x"00000200", 1);
                    push_single_read(net, AxiSlave_c, x"0200", x"120A");
                    expectRdData(net, x"120A");
                    expectRdResponse(RespSuccess);
                end if;

            ---------------------------------------------------------------------------------------
            elsif run("BurstWrite") then

                if ImplWrite_g then
                    pushCommand(net, WrCmdMaster_c, x"00000100", 12);
                    pushWrData(net, x"1234", 1, 12);
                    expect_burst_write_aligned(net, AxiSlave_c, x"0100", x"1234", 1, 12);
                    expectWrResponse(RespSuccess);
                    check_equal(WrSecCnt, 0, "WrSecCnt");
                    check_equal(WrDedCnt, 0, "WrDedCnt");
                end if;

            ---------------------------------------------------------------------------------------
            elsif run("BurstRead") then

                if ImplRead_g then
                    pushCommand(net, RdCmdMaster_c, x"00000210", 12);
                    push_burst_read_aligned(net, AxiSlave_c, x"0210", x"10EF", 1, 12);
                    expectRdData(net, x"10EF", 1, 12);
                    expectRdResponse(RespSuccess);
                end if;

            ---------------------------------------------------------------------------------------
            elsif run("LongTransfer") then
                -- Transfer longer than both the AXI burst size and the internal FIFO of the
                -- wrapped master: proves the external ECC buffer streams through the small
                -- internal FIFO across burst boundaries without throughput deadlock.

                if ImplWrite_g then
                    pushCommand(net, WrCmdMaster_c, x"00004000", 40);
                    pushWrData(net, x"0500", 1, 40);
                    expect_burst_write_aligned(net, AxiSlave_c, x"4000", x"0500", 1, 16);
                    expect_burst_write_aligned(net, AxiSlave_c, x"4000" + 16 * ByteWidth_c, x"0510", 1, 16);
                    expect_burst_write_aligned(net, AxiSlave_c, x"4000" + 32 * ByteWidth_c, x"0520", 1, 8);
                    expectWrResponse(RespSuccess);
                    check_equal(WrSecCnt, 0, "WrSecCnt");
                    check_equal(WrDedCnt, 0, "WrDedCnt");
                end if;

                if ImplRead_g then
                    pushCommand(net, RdCmdMaster_c, x"00005000", 40);
                    push_burst_read_aligned(net, AxiSlave_c, x"5000", x"0900", 1, 16);
                    push_burst_read_aligned(net, AxiSlave_c, x"5000" + 16 * ByteWidth_c, x"0910", 1, 16);
                    push_burst_read_aligned(net, AxiSlave_c, x"5000" + 32 * ByteWidth_c, x"0920", 1, 8);
                    expectRdData(net, x"0900", 1, 40);
                    expectRdResponse(RespSuccess);
                end if;

            ---------------------------------------------------------------------------------------
            elsif run("WriteSecInjection") then
                -- A single-bit flip on the stored {Be, Data} codeword must be corrected before
                -- the beat reaches the AXI bus, and reported with exactly one Wr_EccSec pulse.

                if ImplWrite_g then
                    Flip_v := setBits(1, WrCodewordWid_c);

                    wait until rising_edge(Clk);
                    Wr_ErrInj_BitFlip <= Flip_v;
                    Wr_ErrInj_Valid   <= '1';
                    wait until rising_edge(Clk);
                    Wr_ErrInj_BitFlip <= (others => '0');
                    Wr_ErrInj_Valid   <= '0';

                    pushCommand(net, WrCmdMaster_c, x"00002000", 1);
                    pushWrData(net, x"BEEF");
                    expect_single_write(net, AxiSlave_c, x"2000", x"BEEF");
                    expectWrResponse(RespSuccess);
                    check_equal(WrSecCnt, 1, "WrSecCnt");
                    check_equal(WrDedCnt, 0, "WrDedCnt");
                end if;

            ---------------------------------------------------------------------------------------
            elsif run("WriteDedInjection") then
                -- A double-bit flip is uncorrectable: the deterministic decoder output reaches
                -- the AXI bus and exactly one Wr_EccDed pulse is reported.

                if ImplWrite_g then
                    Flip_v := setBits((0, 1), WrCodewordWid_c);

                    -- Compute the deterministic decode outcome of the flipped {Be, Data} bundle
                    Bundle_v                              := (others => '0');
                    Bundle_v(DatBeRange_c)                := (others => '1');
                    Bundle_v(AxiDataWidth_g - 1 downto 0) := std_logic_vector(resize(unsigned'(x"CAFE"), AxiDataWidth_g));
                    ftExpectedBeat(Bundle_v, Flip_v, Dec_v, Sec_v, Ded_v);
                    check_equal(Ded_v, '1', "flip pattern must be DED");
                    check_equal(Dec_v(DatBeRange_c), onesVector(ByteWidth_c), "BE must stay intact for this pattern");

                    wait until rising_edge(Clk);
                    Wr_ErrInj_BitFlip <= Flip_v;
                    Wr_ErrInj_Valid   <= '1';
                    wait until rising_edge(Clk);
                    Wr_ErrInj_BitFlip <= (others => '0');
                    Wr_ErrInj_Valid   <= '0';

                    pushCommand(net, WrCmdMaster_c, x"00002100", 1);
                    pushWrData(net, x"CAFE");
                    expect_single_write(net, AxiSlave_c, x"2100", unsigned(Dec_v(AxiDataWidth_g - 1 downto 0)));
                    expectWrResponse(RespSuccess);
                    check_equal(WrSecCnt, 0, "WrSecCnt");
                    check_equal(WrDedCnt, 1, "WrDedCnt");
                end if;

            ---------------------------------------------------------------------------------------
            elsif run("ReadSecInjection") then
                -- A single-bit flip on the stored {Last, Data} codeword must be corrected before
                -- the beat reaches the user, flagged on Rd_EccSec (tuser).

                if ImplRead_g then
                    RdFlip_v := setBits(2, RdCodewordWid_c);

                    wait until rising_edge(Clk);
                    Rd_ErrInj_BitFlip <= RdFlip_v;
                    Rd_ErrInj_Valid   <= '1';
                    wait until rising_edge(Clk);
                    Rd_ErrInj_BitFlip <= (others => '0');
                    Rd_ErrInj_Valid   <= '0';

                    pushCommand(net, RdCmdMaster_c, x"00003000", 1);
                    push_single_read(net, AxiSlave_c, x"3000", x"1A2B");
                    expectRdBeatFlipped(net, std_logic_vector(resize(unsigned'(x"1A2B"), AxiDataWidth_g)), '1',
                                        RdFlip_v, "Read SEC beat");
                    expectRdResponse(RespSuccess);
                end if;

            ---------------------------------------------------------------------------------------
            elsif run("ReadDedInjection") then
                -- A double-bit flip is uncorrectable: the deterministic decoder output reaches
                -- the user with Rd_EccDed flagged (tuser).

                if ImplRead_g then
                    RdFlip_v := setBits((1, 3), RdCodewordWid_c);

                    wait until rising_edge(Clk);
                    Rd_ErrInj_BitFlip <= RdFlip_v;
                    Rd_ErrInj_Valid   <= '1';
                    wait until rising_edge(Clk);
                    Rd_ErrInj_BitFlip <= (others => '0');
                    Rd_ErrInj_Valid   <= '0';

                    pushCommand(net, RdCmdMaster_c, x"00003100", 1);
                    push_single_read(net, AxiSlave_c, x"3100", x"3C4D");
                    expectRdBeatFlipped(net, std_logic_vector(resize(unsigned'(x"3C4D"), AxiDataWidth_g)), '1',
                                        RdFlip_v, "Read DED beat");
                    expectRdResponse(RespSuccess);
                end if;

            end if;

            wait_until_idle(net, as_sync(AxiSlave_c));
            wait_until_idle(net, as_sync(WrCmdMaster_c));
            wait_until_idle(net, as_sync(RdCmdMaster_c));
            wait_until_idle(net, as_sync(WrDataMaster_c));
            wait_until_idle(net, as_sync(RdDataSlave_c));
            wait for 1 us;

        end loop;

        test_runner_cleanup(runner);
    end process;

    -----------------------------------------------------------------------------------------------
    -- Clock
    -----------------------------------------------------------------------------------------------
    Clk <= not Clk after 0.5 * Clk_Period_c;

    -----------------------------------------------------------------------------------------------
    -- Write-flag pulse counters
    -----------------------------------------------------------------------------------------------
    p_wrcnt : process (Clk) is
    begin
        if rising_edge(Clk) then

            if Wr_EccSec = '1' then
                WrSecCnt <= WrSecCnt + 1;
            end if;

            if Wr_EccDed = '1' then
                WrDedCnt <= WrDedCnt + 1;
            end if;

            if CntClr = '1' then
                WrSecCnt <= 0;
                WrDedCnt <= 0;
            end if;
        end if;
    end process;

    Rd_TUser <= Rd_EccSec & Rd_EccDed;

    -----------------------------------------------------------------------------------------------
    -- DUT
    -----------------------------------------------------------------------------------------------
    i_dut : entity olo.olo_ft_axi_master_simple
        generic map (
            AxiAddrWidth_g            => AxiAddrWidth_c,
            AxiDataWidth_g            => AxiDataWidth_g,
            AxiMaxBeats_g             => AxiMaxBeats_c,
            AxiMaxOpenTransactions_g  => AxiMaxOpenTransactions_c,
            UserTransactionSizeBits_g => UserTransactionSizeBits_c,
            DataFifoDepth_g           => DataFifoDepth_c,
            ImplRead_g                => ImplRead_g,
            ImplWrite_g               => ImplWrite_g
        )
        port map (
            Clk               => Clk,
            Rst               => Rst,
            CmdWr_Addr        => CmdWr_Addr,
            CmdWr_Size        => CmdWr_Size,
            CmdWr_LowLat      => CmdWr_LowLat,
            CmdWr_Valid       => CmdWr_Valid,
            CmdWr_Ready       => CmdWr_Ready,
            CmdRd_Addr        => CmdRd_Addr,
            CmdRd_Size        => CmdRd_Size,
            CmdRd_LowLat      => CmdRd_LowLat,
            CmdRd_Valid       => CmdRd_Valid,
            CmdRd_Ready       => CmdRd_Ready,
            Wr_Data           => Wr_Data,
            Wr_Be             => Wr_Be,
            Wr_Valid          => Wr_Valid,
            Wr_Ready          => Wr_Ready,
            Wr_EccSec         => Wr_EccSec,
            Wr_EccDed         => Wr_EccDed,
            Rd_Data           => Rd_Data,
            Rd_Last           => Rd_Last,
            Rd_Valid          => Rd_Valid,
            Rd_Ready          => Rd_Ready,
            Rd_EccSec         => Rd_EccSec,
            Rd_EccDed         => Rd_EccDed,
            Wr_Done           => Wr_Done,
            Wr_Error          => Wr_Error,
            Rd_Done           => Rd_Done,
            Rd_Error          => Rd_Error,
            Wr_ErrInj_BitFlip => Wr_ErrInj_BitFlip,
            Wr_ErrInj_Valid   => Wr_ErrInj_Valid,
            Rd_ErrInj_BitFlip => Rd_ErrInj_BitFlip,
            Rd_ErrInj_Valid   => Rd_ErrInj_Valid,
            M_Axi_AwAddr      => AxiMs.aw_addr,
            M_Axi_AwValid     => AxiMs.aw_valid,
            M_Axi_AwReady     => AxiSm.aw_ready,
            M_Axi_AwLen       => AxiMs.aw_len,
            M_Axi_AwSize      => AxiMs.aw_size,
            M_Axi_AwBurst     => AxiMs.aw_burst,
            M_Axi_AwLock      => AxiMs.aw_lock,
            M_Axi_AwCache     => AxiMs.aw_cache,
            M_Axi_AwProt      => AxiMs.aw_prot,
            M_Axi_WData       => AxiMs.w_data,
            M_Axi_WStrb       => AxiMs.w_strb,
            M_Axi_WValid      => AxiMs.w_valid,
            M_Axi_WReady      => AxiSm.w_ready,
            M_Axi_WLast       => AxiMs.w_last,
            M_Axi_BResp       => AxiSm.b_resp,
            M_Axi_BValid      => AxiSm.b_valid,
            M_Axi_BReady      => AxiMs.b_ready,
            M_Axi_ArAddr      => AxiMs.ar_addr,
            M_Axi_ArValid     => AxiMs.ar_valid,
            M_Axi_ArReady     => AxiSm.ar_ready,
            M_Axi_ArLen       => AxiMs.ar_len,
            M_Axi_ArSize      => AxiMs.ar_size,
            M_Axi_ArBurst     => AxiMs.ar_burst,
            M_Axi_ArLock      => AxiMs.ar_lock,
            M_Axi_ArCache     => AxiMs.ar_cache,
            M_Axi_ArProt      => AxiMs.ar_prot,
            M_Axi_RData       => AxiSm.r_data,
            M_Axi_RValid      => AxiSm.r_valid,
            M_Axi_RReady      => AxiMs.r_ready,
            M_Axi_RResp       => AxiSm.r_resp,
            M_Axi_RLast       => AxiSm.r_last
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
            TLast  => Rd_Last,
            TUser  => Rd_TUser
        );

    b_wr_cmd : block is
        signal TDataLocal : std_logic_vector(CmdLowLat_c downto 0);
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
    end block;

    b_rd_cmd : block is
        signal TDataLocal : std_logic_vector(CmdLowLat_c downto 0);
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
