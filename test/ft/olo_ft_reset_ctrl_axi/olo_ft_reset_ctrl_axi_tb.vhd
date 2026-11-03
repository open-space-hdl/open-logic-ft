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
    use olo.olo_axi_pkg_protocol.all;

library work;
    use work.olo_test_pkg_axi.all;
    use work.olo_test_axi_master_pkg.all;

---------------------------------------------------------------------------------------------------
-- Entity
---------------------------------------------------------------------------------------------------
entity olo_ft_reset_ctrl_axi_tb is
    generic (
        runner_cfg       : string;
        RstPulseCycles_g : positive range 1 to 65535 := 16;
        AxiAddrWidth_g   : positive range 4 to 30    := 12;
        AltKey_g         : boolean                   := false
    );
end entity;

---------------------------------------------------------------------------------------------------
-- Architecture
---------------------------------------------------------------------------------------------------
architecture sim of olo_ft_reset_ctrl_axi_tb is

    -----------------------------------------------------------------------------------------------
    -- Constants
    -----------------------------------------------------------------------------------------------
    constant ClkPeriod_c  : time                          := 10 ns;
    constant DefaultKey_c : std_logic_vector(31 downto 0) := x"50495045";
    constant Key_c        : std_logic_vector(31 downto 0) := choose(AltKey_g, x"A55AC33C", DefaultKey_c);
    constant Id_c         : std_logic_vector(31 downto 0) := x"52535401";
    constant IdAddr_c     : natural                       := 16#00#;
    constant CtrlAddr_c   : natural                       := 16#04#;
    constant StatusAddr_c : natural                       := 16#08#;
    constant N_c          : positive                      := RstPulseCycles_g;

    -- Expected STATUS word
    function statusWord (count : natural; busy : std_logic) return unsigned is
    begin
        return unsigned(toUslv(count, 16) & toUslv(0, 15) & busy);
    end function;

    -- 32-bit word with one bit set
    function bitMask (idx : natural) return std_logic_vector is
        variable Mask_v : std_logic_vector(31 downto 0) := (others => '0');
    begin
        Mask_v(idx) := '1';
        return Mask_v;
    end function;

    -----------------------------------------------------------------------------------------------
    -- AXI Definition
    -----------------------------------------------------------------------------------------------
    constant IdWidth_c   : integer := 0;
    constant AddrWidth_c : integer := AxiAddrWidth_g;
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
    signal Clk    : std_logic := '0';
    signal Rst    : std_logic := '1';
    signal RstOut : std_logic;

    -- BReady of the DUT: the VC's BReady, or forced to '1' by the bench to place the write
    -- response handshake on an exact clock edge
    signal BReadyForce : std_logic := '0';
    signal BReady      : std_logic;

    -- Statistics of the monitor
    signal MonRises   : natural := 0; -- rising edges of RstOut
    signal MonLastLen : natural := 0; -- length of the last completed RstOut pulse in cycles
    signal MonBResp   : natural := 0; -- write response handshakes

begin

    -----------------------------------------------------------------------------------------------
    -- Clock
    -----------------------------------------------------------------------------------------------
    Clk <= not Clk after 0.5 * ClkPeriod_c;

    -----------------------------------------------------------------------------------------------
    -- DUT
    -----------------------------------------------------------------------------------------------
    BReady <= AxiMs.b_ready or BReadyForce;

    i_dut : entity olo.olo_ft_reset_ctrl_axi
        generic map (
            RstPulseCycles_g => RstPulseCycles_g,
            Key_g            => Key_c,
            AxiAddrWidth_g   => AxiAddrWidth_g
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
            S_AxiLite_BReady  => BReady,
            S_AxiLite_RData   => AxiSm.r_data,
            S_AxiLite_RResp   => AxiSm.r_resp,
            S_AxiLite_RValid  => AxiSm.r_valid,
            S_AxiLite_RReady  => AxiMs.r_ready,
            RstOut            => RstOut
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
    -- RstOut Monitor
    -----------------------------------------------------------------------------------------------
    -- Reference model built from the AXI channels: a command is the write response handshake of a
    -- write of the key with all byte strobes to CTRL. RstOut is checked in every clock cycle.
    p_monitor : process is
        variable AwAddr_v    : std_logic_vector(AxiAddrWidth_g - 1 downto 0) := (others => '0');
        variable WData_v     : std_logic_vector(31 downto 0)                 := (others => '0');
        variable WStrb_v     : std_logic_vector(3 downto 0)                  := (others => '0');
        variable PulseCnt_v  : natural                                       := 0;
        variable ExpRstOut_v : std_logic                                     := '1';
        variable Prev_v      : std_logic                                     := '1';
        variable HighLen_v   : natural                                       := 0;
    begin
        wait until rising_edge(Clk);

        -- Address and data of the current write transaction
        if (AxiMs.aw_valid = '1') and (AxiSm.aw_ready = '1') then
            AwAddr_v := AxiMs.aw_addr;
        end if;
        if (AxiMs.w_valid = '1') and (AxiSm.w_ready = '1') then
            WData_v := AxiMs.w_data;
            WStrb_v := AxiMs.w_strb;
        end if;

        if (AxiSm.b_valid = '1') and (BReady = '1') then
            MonBResp <= MonBResp + 1;
        end if;

        -- Expected pulse
        if Rst = '1' then
            PulseCnt_v := 0;
        elsif (AxiSm.b_valid = '1') and (BReady = '1') and
              (fromUslv(AwAddr_v(AxiAddrWidth_g - 1 downto 2)) = CtrlAddr_c / 4) and
              (WData_v = Key_c) and (WStrb_v = "1111") then
            PulseCnt_v := N_c;
        elsif PulseCnt_v > 0 then
            PulseCnt_v := PulseCnt_v - 1;
        end if;
        if (Rst = '1') or (PulseCnt_v > 0) then
            ExpRstOut_v := '1';
        else
            ExpRstOut_v := '0';
        end if;

        -- Check in the middle of the cycle
        wait until falling_edge(Clk);
        check_equal(RstOut, ExpRstOut_v, "RstOut");

        -- Statistics
        if (RstOut = '1') and (Prev_v = '0') then
            MonRises  <= MonRises + 1;
            HighLen_v := 1;
        elsif RstOut = '1' then
            HighLen_v := HighLen_v + 1;
        elsif Prev_v = '1' then
            MonLastLen <= HighLen_v;
        end if;
        Prev_v := RstOut;
    end process;

    -----------------------------------------------------------------------------------------------
    -- TB Control
    -----------------------------------------------------------------------------------------------
    test_runner_watchdog(runner, 100 ms);

    p_control : process is
        variable Rises_v : natural;

        -- Single register write through the VC, waits for the write response
        procedure writeReg (
            addr : natural;
            data : std_logic_vector(31 downto 0);
            strb : std_logic_vector(3 downto 0) := "1111") is
        begin
            push_single_write(net, AxiMaster_c,
                addr => to_unsigned(addr, AxiAddrWidth_g),
                data => unsigned(data),
                strb => strb);
            wait_until_idle(net, as_sync(AxiMaster_c));
        end procedure;

        -- Single register read through the VC with the expected data
        procedure checkReg (
            addr : natural;
            data : unsigned) is
        begin
            expect_single_read(net, AxiMaster_c,
                addr => to_unsigned(addr, AxiAddrWidth_g),
                data => data);
            wait_until_idle(net, as_sync(AxiMaster_c));
        end procedure;

        -- Write address and data through the VC without a write response; the bench completes
        -- the transaction with BReadyForce
        procedure pushWriteNoResp (
            addr : natural;
            data : std_logic_vector(31 downto 0)) is
        begin
            push_aw(net, AxiMaster_c, addr => to_unsigned(addr, AxiAddrWidth_g));
            push_w(net, AxiMaster_c, start_value => unsigned(data));
        end procedure;

        -- Waits until the monitor has seen a number of write response handshakes in total
        procedure waitBResp (
            total : natural) is
        begin
            if MonBResp < total then
                wait until MonBResp >= total;
            end if;
        end procedure;

        -- Single register write with BReadyForce = '1', waits for the write response handshake
        procedure writeForced (
            addr : natural;
            data : std_logic_vector(31 downto 0)) is
            variable Total_v : natural;
        begin
            Total_v := MonBResp + 1;
            pushWriteNoResp(addr, data);
            waitBResp(Total_v);
        end procedure;

        -- Waits until BValid is '1' and places the write response handshake on the next edge
        procedure handshakeNow is
        begin

            while AxiSm.b_valid /= '1' loop
                wait until rising_edge(Clk);
            end loop;

            BReadyForce <= '1';
            wait until rising_edge(Clk);
            BReadyForce <= '0';
        end procedure;

        -- Waits until the RstOut pulse is over and the statistics of the monitor are updated
        procedure waitPulseEnd is
        begin
            wait until falling_edge(Clk);

            while RstOut = '1' loop
                wait until falling_edge(Clk);
            end loop;

            wait until rising_edge(Clk);
        end procedure;

        -- Reset of the DUT for a number of cycles
        procedure applyRst (
            cycles : positive) is
        begin
            wait until rising_edge(Clk);
            Rst <= '1';

            for i in 1 to cycles loop
                wait until rising_edge(Clk);
            end loop;

            Rst <= '0';
        end procedure;

        variable Cmds_v : natural;
    begin
        test_runner_setup(runner, runner_cfg);

        -- Power-up value, before the first clock edge
        check_equal(RstOut, '1', "RstOut at power-up");

        while test_suite loop
            -- Reset between cases
            applyRst(20);
            waitPulseEnd;

            if run("Reset") then
                -- RC-04, RC-09: register content after the reset
                checkReg(IdAddr_c, unsigned(Id_c));
                checkReg(CtrlAddr_c, to_unsigned(0, 32));
                checkReg(StatusAddr_c, statusWord(0, '0'));
                check_equal(MonRises, 0, "no pulse after the reset");
                -- RC-04: a reset of one cycle gives RstOut for one cycle, one cycle late
                applyRst(1);
                waitPulseEnd;
                check_equal(MonRises, 1, "pulse of the one-cycle reset");
                check_equal(MonLastLen, 1, "length of the pulse of the one-cycle reset");

            elsif run("Command") then
                -- RC-02, RC-05, RC-06: one command, BReady from the VC
                writeReg(CtrlAddr_c, Key_c);
                if N_c >= 16 then
                    checkReg(StatusAddr_c, statusWord(1, '1'));
                end if;
                waitPulseEnd;
                check_equal(MonRises, 1, "one pulse");
                check_equal(MonLastLen, N_c, "pulse length");
                checkReg(StatusAddr_c, statusWord(1, '0'));
                checkReg(CtrlAddr_c, to_unsigned(0, 32));

            elsif run("BReadyEarly") then
                -- RC-02: BReady already '1' when BValid rises (handshake in the cycle of the
                -- register write)
                BReadyForce <= '1';
                writeForced(CtrlAddr_c, Key_c);
                waitPulseEnd;
                check_equal(MonRises, 1, "one pulse");
                check_equal(MonLastLen, N_c, "pulse length");
                -- A following write without the key does not act
                writeForced(CtrlAddr_c, not Key_c);

                for i in 1 to N_c + 4 loop
                    wait until rising_edge(Clk);
                end loop;

                check_equal(MonRises, 1, "no pulse without the key");
                BReadyForce <= '0';
                checkReg(StatusAddr_c, statusWord(1, '0'));

            elsif run("BReadyHeld") then
                -- RC-02: BReady held off by the master delays the command
                push_single_write(net, AxiMaster_c,
                    addr          => to_unsigned(CtrlAddr_c, AxiAddrWidth_g),
                    data          => unsigned(Key_c),
                    b_ready_delay => 20 * ClkPeriod_c);
                wait_until_idle(net, as_sync(AxiMaster_c));
                waitPulseEnd;
                check_equal(MonRises, 1, "one pulse");
                check_equal(MonLastLen, N_c, "pulse length");
                -- Held-off response handshake placed by the bench
                pushWriteNoResp(CtrlAddr_c, Key_c);
                wait until rising_edge(Clk) and AxiSm.b_valid = '1';

                for i in 1 to 30 loop
                    wait until rising_edge(Clk);
                end loop;

                check_equal(MonRises, 1, "no pulse before the handshake");
                handshakeNow;
                waitPulseEnd;
                check_equal(MonRises, 2, "second pulse");
                check_equal(MonLastLen, N_c, "pulse length");
                checkReg(StatusAddr_c, statusWord(2, '0'));

            elsif run("NoCommand") then
                -- RC-01: writes to CTRL that are not a command
                writeReg(CtrlAddr_c, x"00000000");
                writeReg(CtrlAddr_c, x"FFFFFFFF");
                writeReg(CtrlAddr_c, not Key_c);
                if AltKey_g then
                    writeReg(CtrlAddr_c, DefaultKey_c);
                end if;

                -- Every single-bit error of the key
                for i in 0 to 31 loop
                    writeReg(CtrlAddr_c, Key_c xor bitMask(i));
                end loop;

                -- Every partial write of the key
                for i in 0 to 14 loop
                    writeReg(CtrlAddr_c, Key_c, toUslv(i, 4));
                end loop;

                for i in 1 to N_c + 4 loop
                    wait until rising_edge(Clk);
                end loop;

                check_equal(MonRises, 0, "no pulse");
                checkReg(StatusAddr_c, statusWord(0, '0'));

            elsif run("WrongAddress") then
                -- RC-01, RC-09: the key written to other words is ignored, response OKAY
                writeReg(IdAddr_c, Key_c);
                writeReg(StatusAddr_c, Key_c);
                writeReg(16#0C#, Key_c);
                writeReg(2**AxiAddrWidth_g - 4, Key_c);

                -- Aliases of CTRL with one upper address bit set (full address decode)
                for i in 4 to AxiAddrWidth_g - 1 loop
                    writeReg(CtrlAddr_c + 2**i, Key_c);
                end loop;

                for i in 1 to N_c + 4 loop
                    wait until rising_edge(Clk);
                end loop;

                check_equal(MonRises, 0, "no pulse");
                checkReg(IdAddr_c, unsigned(Id_c));
                checkReg(StatusAddr_c, statusWord(0, '0'));

            elsif run("Restart") then
                -- RC-03, RC-06, RC-08: a second command j cycles after the first one. The earliest
                -- second handshake after the first is 5 cycles (AXI-Lite slave). j <= N_c restarts
                -- the pulse without a gap, j = N_c + 1 gives a second pulse after one cycle low.
                Rises_v := 0;
                Cmds_v  := 0;

                for j in 5 to max(N_c + 1, 5) loop
                    -- Restart early, in the middle, at the end of the pulse and one cycle late
                    if (j <= 6) or (j = N_c / 2) or (j >= N_c - 1) then
                        -- First command, handshake at edge e1
                        pushWriteNoResp(CtrlAddr_c, Key_c);
                        handshakeNow;
                        -- Second command, handshake at edge e1 + j
                        pushWriteNoResp(CtrlAddr_c, Key_c);

                        for i in 1 to j - 1 loop
                            wait until rising_edge(Clk);
                        end loop;

                        BReadyForce <= '1';
                        wait until rising_edge(Clk);
                        BReadyForce <= '0';
                        check_equal(AxiSm.b_valid, '1', "second write response at e1 + j, j = " & integer'image(j));
                        wait_until_idle(net, as_sync(AxiMaster_c));
                        waitPulseEnd;
                        Cmds_v      := Cmds_v + 2;

                        if j <= N_c then
                            Rises_v := Rises_v + 1;
                            check_equal(MonLastLen, j + N_c, "restarted pulse length, j = " & integer'image(j));
                        else
                            Rises_v := Rises_v + 2;
                            check_equal(MonLastLen, N_c, "second pulse length, j = " & integer'image(j));
                        end if;
                        check_equal(MonRises, Rises_v, "pulses, j = " & integer'image(j));
                    end if;
                end loop;

                checkReg(StatusAddr_c, statusWord(Cmds_v, '0'));

            elsif run("RstDuringPulse") then
                -- RC-04: Rst ends a running pulse and clears COUNT. Rst is '1' at the two edges
                -- after the handshake edge e1, RstOut falls at e1 + 3 for every pulse length.
                pushWriteNoResp(CtrlAddr_c, Key_c);
                handshakeNow;
                Rst <= '1';
                wait until rising_edge(Clk);
                wait until rising_edge(Clk);
                Rst <= '0';
                waitPulseEnd;
                check_equal(MonRises, 1, "one pulse");
                check_equal(MonLastLen, 3, "pulse ended by Rst");
                checkReg(StatusAddr_c, statusWord(0, '0'));
                -- Rst on the edge of the write response handshake wins: RstOut for the one cycle
                -- of Rst, COUNT stays zero
                pushWriteNoResp(CtrlAddr_c, Key_c);

                while AxiSm.b_valid /= '1' loop
                    wait until rising_edge(Clk);
                end loop;

                BReadyForce <= '1';
                Rst         <= '1';
                wait until rising_edge(Clk);
                BReadyForce <= '0';
                Rst         <= '0';
                waitPulseEnd;
                check_equal(MonRises, 2, "pulse of the reset");
                check_equal(MonLastLen, 1, "no command pulse at the reset");
                checkReg(StatusAddr_c, statusWord(0, '0'));
                -- Commands work after the reset
                writeReg(CtrlAddr_c, Key_c);
                waitPulseEnd;
                check_equal(MonRises, 3, "pulse after the reset");
                check_equal(MonLastLen, N_c, "pulse length");
                checkReg(StatusAddr_c, statusWord(1, '0'));

            elsif run("CountSaturation") then
                -- RC-06: COUNT saturates at 0xFFFF
                BReadyForce <= '1';
                Cmds_v      := MonBResp + 2**16 - 2;

                for i in 1 to 2**16 - 2 loop
                    pushWriteNoResp(CtrlAddr_c, Key_c);
                    if i mod 256 = 0 then
                        wait_until_idle(net, as_sync(AxiMaster_c));
                    end if;
                end loop;

                waitBResp(Cmds_v);
                waitPulseEnd;
                checkReg(StatusAddr_c, statusWord(2**16 - 2, '0'));
                writeForced(CtrlAddr_c, Key_c);
                waitPulseEnd;
                checkReg(StatusAddr_c, statusWord(2**16 - 1, '0'));
                writeForced(CtrlAddr_c, Key_c);
                waitPulseEnd;
                checkReg(StatusAddr_c, statusWord(2**16 - 1, '0'));
                BReadyForce <= '0';

            elsif run("UnmappedRead") then
                -- RC-09: unmapped reads end in the read timeout of the slave with an error
                push_ar(net, AxiMaster_c, addr => to_unsigned(16#0C#, AxiAddrWidth_g));
                expect_r(net, AxiMaster_c, X"0", resp => AxiResp_SlvErr_c, ignore_data => true);
                push_ar(net, AxiMaster_c, addr => to_unsigned(2**AxiAddrWidth_g - 4, AxiAddrWidth_g));
                expect_r(net, AxiMaster_c, X"0", resp => AxiResp_SlvErr_c, ignore_data => true);

                for i in 4 to AxiAddrWidth_g - 1 loop
                    push_ar(net, AxiMaster_c, addr => to_unsigned(StatusAddr_c + 2**i, AxiAddrWidth_g));
                    expect_r(net, AxiMaster_c, X"0", resp => AxiResp_SlvErr_c, ignore_data => true);
                end loop;

                wait_until_idle(net, as_sync(AxiMaster_c));
                checkReg(IdAddr_c, unsigned(Id_c));
                check_equal(MonRises, 0, "no pulse");
            end if;

            wait_until_idle(net, as_sync(AxiMaster_c));

        end loop;

        test_runner_cleanup(runner);
    end process;

end architecture;
