---------------------------------------------------------------------------------------------------
-- Copyright (c) 2026 by Julian Schneider
-- Authors: Julian Schneider
---------------------------------------------------------------------------------------------------

---------------------------------------------------------------------------------------------------
-- Description
---------------------------------------------------------------------------------------------------
-- Testbench of olo_intf_can. Two DUTs (A and B) and a bus functional model (BFM) share a wired-AND bus;
-- every DUT sees the bus through a loop delay. The BFM is an independent node with ideal timing that
-- sends bit streams and samples the bus; the reference bit streams of the frames (CRC, stuffing) come
-- from the Python model (cosim.py). Section numbers refer to the Bosch CAN Specification 2.0 part B.

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
    use vunit_lib.integer_array_pkg.all;
    use vunit_lib.queue_pkg.all;

library olo;
    use olo.olo_base_pkg_math.all;
    use olo.olo_base_pkg_logic.all;

---------------------------------------------------------------------------------------------------
-- Entity
---------------------------------------------------------------------------------------------------
entity olo_intf_can_tb is
    generic (
        runner_cfg      : string;
        Prescaler_g     : positive := 4;
        Tseg1_g         : positive := 6;
        Tseg2_g         : positive := 3;
        Sjw_g           : positive := 2;
        AutoRecover_g   : boolean  := true;
        SyncTmr_g       : boolean  := false;
        ClkBOffsetPpm_g : integer  := 0
    );
end entity;

architecture sim of olo_intf_can_tb is

    -----------------------------------------------------------------------------------------------
    -- Constants
    -----------------------------------------------------------------------------------------------
    constant ClkPeriod_c  : time     := 25 ns; -- 40 MHz
    constant ClkBPeriod_c : time     := ClkPeriod_c * (1.0 + real(ClkBOffsetPpm_g) * 1.0e-6);
    constant TqPerBit_c   : positive := 1 + Tseg1_g + Tseg2_g;
    constant Tq_c         : time     := ClkPeriod_c * Prescaler_g;
    constant BitTime_c    : time     := Tq_c * TqPerBit_c;
    constant SampleFrac_c : real     := real(1 + Tseg1_g) / real(TqPerBit_c);
    constant MaxBits_c    : positive := 180;
    constant Cols_c       : positive := 15; -- columns before the bits in the model files
    -- Delay from Can_Tx over the bus and the transceiver back to Can_Rx (at most a tenth of a bit)
    constant LoopDelay_c  : time := minimum(100 ns, BitTime_c / 10);
    -- Sample point of A for a bit that starts on the bus at time 0 (A synchronized to the bus): loop delay,
    -- synchronizer and edge detection, then the sample point of the bit
    constant ASample_c    : time := LoopDelay_c + ClkPeriod_c * 3 + BitTime_c * SampleFrac_c;
    -- Lag of the bits of a transmitting DUT behind its start of frame edge: it synchronizes to its own echo
    -- (loop delay, synchronizer, edge detection) and drives through its output register
    constant TxLag_c      : time := LoopDelay_c + ClkPeriod_c * 4;
    -- Width of the glitches of the synchronization tests: half a time quantum, at least a clock period
    constant Glitch_c     : time := maximum(Tq_c / 2, ClkPeriod_c);

    -- Oscillator tolerance of the bit timing (Bosch 2.0 part B section 9 and the usual conditions
    -- df <= SJW / (20 * bit time) and df <= min(PHASE_SEG1, PHASE_SEG2) / (2 * (13 * bit time - PHASE_SEG2)))
    constant PhaseSeg_c  : real := real(minimum(Tseg1_g - 1, Tseg2_g));
    constant Tolerance_c : real := minimum(real(Sjw_g) / (20.0 * real(TqPerBit_c)),
                                           PhaseSeg_c / (2.0 * (13.0 * real(TqPerBit_c) - real(Tseg2_g))));

    -----------------------------------------------------------------------------------------------
    -- Types
    -----------------------------------------------------------------------------------------------
    type Frame_t is record
        Id         : std_logic_vector(28 downto 0);
        Ide        : std_logic;
        Rtr        : std_logic;
        Dlc        : std_logic_vector(3 downto 0);
        Data       : std_logic_vector(63 downto 0);
        NBits      : natural;
        AckIdx     : natural;
        FirstStuff : integer;
        Bits       : std_logic_vector(0 to MaxBits_c - 1);
    end record;

    -----------------------------------------------------------------------------------------------
    -- Interface Signals
    -----------------------------------------------------------------------------------------------
    signal Clk  : std_logic := '0';
    signal ClkB : std_logic := '0';
    signal Rst  : std_logic := '1';
    signal RstB : std_logic := '1';

    -- DUT A
    signal EnableA     : std_logic                     := '1';
    signal ListenOnlyA : std_logic                     := '0';
    signal LoopbackA   : std_logic                     := '0';
    signal RecoverA    : std_logic                     := '0';
    signal TxValidA    : std_logic                     := '0';
    signal TxReadyA    : std_logic;
    signal TxIdA       : std_logic_vector(28 downto 0) := (others => '0');
    signal TxIdeA      : std_logic                     := '0';
    signal TxRtrA      : std_logic                     := '0';
    signal TxDlcA      : std_logic_vector(3 downto 0)  := (others => '0');
    signal TxDataA     : std_logic_vector(63 downto 0) := (others => '0');
    signal TxAbortA    : std_logic                     := '0';
    signal TxDoneA     : std_logic;
    signal TxAbortedA  : std_logic;
    signal TxArbLostA  : std_logic;
    signal RxValidA    : std_logic;
    signal RxIdA       : std_logic_vector(28 downto 0);
    signal RxIdeA      : std_logic;
    signal RxRtrA      : std_logic;
    signal RxDlcA      : std_logic_vector(3 downto 0);
    signal RxDataA     : std_logic_vector(63 downto 0);
    signal TecA        : std_logic_vector(8 downto 0);
    signal RecA        : std_logic_vector(7 downto 0);
    signal StateA      : std_logic_vector(1 downto 0);
    signal BusIdleA    : std_logic;
    signal ErrBitA     : std_logic;
    signal ErrStuffA   : std_logic;
    signal ErrCrcA     : std_logic;
    signal ErrFormA    : std_logic;
    signal ErrAckA     : std_logic;
    signal CanTxA      : std_logic;
    signal CanRxA      : std_logic;
    signal RxForceA    : std_logic                     := '0'; -- '1': A sees a recessive bus (receive fault)

    -- DUT B
    signal EnableB    : std_logic                     := '0';
    signal TxValidB   : std_logic                     := '0';
    signal TxReadyB   : std_logic;
    signal TxIdB      : std_logic_vector(28 downto 0) := (others => '0');
    signal TxIdeB     : std_logic                     := '0';
    signal TxRtrB     : std_logic                     := '0';
    signal TxDlcB     : std_logic_vector(3 downto 0)  := (others => '0');
    signal TxDataB    : std_logic_vector(63 downto 0) := (others => '0');
    signal TxDoneB    : std_logic;
    signal TxArbLostB : std_logic;
    signal RxValidB   : std_logic;
    signal RxIdB      : std_logic_vector(28 downto 0);
    signal RxIdeB     : std_logic;
    signal RxRtrB     : std_logic;
    signal RxDlcB     : std_logic_vector(3 downto 0);
    signal RxDataB    : std_logic_vector(63 downto 0);
    signal TecB       : std_logic_vector(8 downto 0);
    signal RecB       : std_logic_vector(7 downto 0);
    signal CanTxB     : std_logic;
    signal CanRxB     : std_logic;

    -- Bus
    signal BfmTx     : std_logic := '1';
    signal CanBus    : std_logic;
    signal BusDelA   : std_logic;
    signal LastFallA : time      := 0 ns; -- last dominant edge driven by A

    -- Event counters
    signal CntRxA       : natural := 0;
    signal CntTxDoneA   : natural := 0;
    signal CntAbortedA  : natural := 0;
    signal CntArbLostA  : natural := 0;
    signal CntErrBitA   : natural := 0;
    signal CntErrStuffA : natural := 0;
    signal CntErrCrcA   : natural := 0;
    signal CntErrFormA  : natural := 0;
    signal CntErrAckA   : natural := 0;
    signal CntRxB       : natural := 0;
    signal CntTxDoneB   : natural := 0;
    signal CntArbLostB  : natural := 0;

    -- Transmit requests
    signal PushFrameA : Frame_t;
    signal PushFrameB : Frame_t;
    signal PushReqA   : natural := 0;
    signal PushReqB   : natural := 0;
    signal PushAckA   : natural := 0;
    signal PushAckB   : natural := 0;

    -- Received frames
    constant RxQueueA_c : queue_t := new_queue;
    constant RxQueueB_c : queue_t := new_queue;

    -- Configuration ports
    constant Prescaler_c : std_logic_vector(9 downto 0) := toUslv(Prescaler_g, 10);
    constant Tseg1_c     : std_logic_vector(4 downto 0) := toUslv(Tseg1_g, 5);
    constant Tseg2_c     : std_logic_vector(3 downto 0) := toUslv(Tseg2_g, 4);
    constant Sjw_c       : std_logic_vector(2 downto 0) := toUslv(Sjw_g, 3);

begin

    -----------------------------------------------------------------------------------------------
    -- TB Control
    -----------------------------------------------------------------------------------------------
    test_runner_watchdog(runner, 200 ms);

    p_control : process is
        variable Frames_v : integer_array_t;
        variable CrcErr_v : integer_array_t;
        variable Resvd_v  : integer_array_t;
        variable F_v      : Frame_t;
        variable G_v      : Frame_t;
        variable H_v      : Frame_t;
        variable Capt_v   : std_logic_vector(0 to MaxBits_c - 1);
        variable Bits_v   : std_logic_vector(0 to MaxBits_c - 1);
        variable Ones_v   : std_logic_vector(0 to MaxBits_c - 1);
        variable Zeros_v  : std_logic_vector(0 to MaxBits_c - 1);
        variable Idx_v    : natural;
        variable T0_v     : time;
        variable Ref_v    : time;
        variable Ref2_v   : time;

        -- *** Frames of the model files ***
        impure function getFrame (arr : integer_array_t; row : natural) return Frame_t is
            variable Fr_v : Frame_t;
        begin
            Fr_v.Id  := std_logic_vector(to_unsigned(get(arr, 0, row), 29));
            Fr_v.Ide := '1' when get(arr, 1, row) = 1 else '0';
            Fr_v.Rtr := '1' when get(arr, 2, row) = 1 else '0';
            Fr_v.Dlc := toUslv(get(arr, 3, row), 4);

            for i in 0 to 7 loop
                Fr_v.Data(63 - 8 * i downto 56 - 8 * i) := toUslv(get(arr, 4 + i, row), 8);
            end loop;

            Fr_v.NBits      := get(arr, 12, row);
            Fr_v.AckIdx     := get(arr, 13, row);
            Fr_v.FirstStuff := get(arr, 14, row);

            for i in 0 to MaxBits_c - 1 loop
                Fr_v.Bits(i) := '1' when get(arr, Cols_c + i, row) = 1 else '0';
            end loop;

            return Fr_v;
        end function;

        -- First recessive (lvl = '1') or dominant bit from index first on
        function findBit (f : Frame_t; first : natural; last : natural; lvl : std_logic) return natural is
        begin

            for i in first to last loop
                if f.Bits(i) = lvl then
                    return i;
                end if;
            end loop;

            return first;
        end function;

        -- *** Waiting ***
        procedure waitBits (n : real) is
        begin
            wait for BitTime_c * n;
        end procedure;

        -- Bus recessive for n consecutive bit times
        procedure waitRecessive (n : real; timeout : time := 5 ms) is
            variable Start_v : time;
        begin
            Start_v := now;

            loop
                if CanBus = '0' then
                    wait until CanBus = '1' for timeout;
                end if;
                wait until CanBus = '0' for BitTime_c * n;
                exit when CanBus = '1';
                if now - Start_v > timeout then
                    error("waitRecessive: timeout");
                    exit;
                end if;
            end loop;

        end procedure;

        procedure waitCount (signal cnt : in natural; target : natural; msg : string; timeout : time := 2 ms) is
        begin
            if cnt < target then
                wait until cnt >= target for timeout;
            end if;
            check(cnt >= target, "timeout waiting for " & msg);
        end procedure;

        -- Receive fault of A for the bit that starts on the bus at bitStart: A sees recessive around its sample point
        procedure forceRx (bitStart : time) is
        begin
            wait for bitStart + ASample_c - BitTime_c * 0.25 - now;
            RxForceA <= '1';
            wait for BitTime_c * 0.5;
            RxForceA <= '0';
        end procedure;

        procedure pulse (signal s : out std_logic) is
        begin
            wait until rising_edge(Clk);
            s <= '1';
            wait until rising_edge(Clk);
            s <= '0';
        end procedure;

        -- *** BFM: send n bits with its own bit time from now on, sample the bus at the sample point ***
        procedure bfmSend (
            bits    : std_logic_vector;
            n       : natural;
            bitTime : time;
            capt    : out std_logic_vector) is
            variable B_v     : std_logic_vector(0 to bits'length - 1) := bits;
            variable Start_v : time;
        begin
            Start_v := now;

            for i in 0 to n - 1 loop
                BfmTx   <= B_v(i);
                wait for Start_v + bitTime * (real(i) + SampleFrac_c) - now;
                capt(i) := CanBus;
                wait for Start_v + bitTime * real(i + 1) - now;
            end loop;

            BfmTx <= '1';
        end procedure;

        -- Frame of the BFM: ACK slot recessive (left to the receivers), optionally one bit overridden and only
        -- the first nBits sent
        procedure bfmSendFrame (
            f       : Frame_t;
            capt    : out std_logic_vector;
            bitTime : time      := BitTime_c;
            ovrIdx  : integer   := -1;
            ovrVal  : std_logic := '0';
            nBits   : integer   := -1) is
            variable B_v : std_logic_vector(0 to MaxBits_c - 1);
            variable N_v : natural;
        begin
            B_v           := f.Bits;
            B_v(f.AckIdx) := '1';
            if ovrIdx >= 0 then
                B_v(ovrIdx) := ovrVal;
            end if;
            N_v := f.NBits when nBits < 0 else nBits;
            bfmSend(B_v, N_v, bitTime, capt);
        end procedure;

        -- *** BFM: capture n bits from the next start of frame (or from sofTime); optionally acknowledge at ackIdx
        -- and force dominant bits from forceIdx on. The BFM drives in the bit timing of the transmitter (TxLag_c
        -- after its own grid), as a receiver synchronized to the transmitter would. ***
        procedure bfmCapture (
            n        : natural;
            ackIdx   : integer;
            capt     : out std_logic_vector;
            forceIdx : integer := -1;
            forceLen : natural := 1;
            sofTime  : time    := 0 ns;
            timeout  : time    := 5 ms) is
            variable Sof_v : time;
        begin
            if sofTime > 0 ns then
                Sof_v := sofTime;
            else
                if CanBus = '1' then
                    wait until CanBus = '0' for timeout;
                end if;
                check_equal(CanBus, '0', "bfmCapture: no start of frame");
                Sof_v := now;
            end if;

            for i in 0 to n - 1 loop
                if Sof_v + BitTime_c * real(i) + TxLag_c > now then
                    wait for Sof_v + BitTime_c * real(i) + TxLag_c - now;
                end if;
                if i = ackIdx or (forceIdx >= 0 and i >= forceIdx and i < forceIdx + forceLen) then
                    BfmTx <= '0';
                else
                    BfmTx <= '1';
                end if;
                wait for Sof_v + BitTime_c * (real(i) + SampleFrac_c) - now;
                capt(i) := CanBus;
            end loop;

            wait for Sof_v + BitTime_c * real(n) + TxLag_c - now;
            BfmTx <= '1';
        end procedure;

        -- *** DUT transmit requests (handed to the push processes; blocking: until the DUT took the frame) ***
        procedure pushTx (f : Frame_t; blocking : boolean := true) is
        begin
            PushFrameA <= f;
            PushReqA   <= PushReqA + 1;
            if blocking then
                wait until PushAckA = PushReqA;
            end if;
        end procedure;

        procedure pushTx2 (f : Frame_t; blocking : boolean := true) is
        begin
            PushFrameB <= f;
            PushReqB   <= PushReqB + 1;
            if blocking then
                wait until PushAckB = PushReqB;
            end if;
        end procedure;

        -- *** Checks ***
        procedure checkBits (
            got   : std_logic_vector;
            exp   : std_logic_vector;
            first : natural;
            n     : natural;
            msg   : string) is
            variable G_v : std_logic_vector(0 to got'length - 1) := got;
            variable E_v : std_logic_vector(0 to exp'length - 1) := exp;
        begin

            for i in first to first + n - 1 loop
                if G_v(i) /= E_v(i) then
                    error(msg & ": bit " & integer'image(i) & " is " & std_logic'image(G_v(i)));
                    return;
                end if;
            end loop;

        end procedure;

        procedure checkLevel (got : std_logic_vector; first : natural; n : natural; lvl : std_logic; msg : string) is
            variable G_v : std_logic_vector(0 to got'length - 1) := got;
        begin

            for i in first to first + n - 1 loop
                if G_v(i) /= lvl then
                    error(msg & ": bit " & integer'image(i) & " is " & std_logic'image(G_v(i)));
                    return;
                end if;
            end loop;

        end procedure;

        procedure checkRx (constant q : queue_t; f : Frame_t; msg : string) is
            variable Id_v    : std_logic_vector(28 downto 0);
            variable Ide_v   : std_logic;
            variable Rtr_v   : std_logic;
            variable Dlc_v   : std_logic_vector(3 downto 0);
            variable Data_v  : std_logic_vector(63 downto 0);
            variable ExpId_v : std_logic_vector(28 downto 0);
        begin
            check(not is_empty(q), msg & ": no frame received");
            if is_empty(q) then
                return;
            end if;
            Id_v    := pop_std_ulogic_vector(q);
            Ide_v   := pop_std_ulogic(q);
            Rtr_v   := pop_std_ulogic(q);
            Dlc_v   := pop_std_ulogic_vector(q);
            Data_v  := pop_std_ulogic_vector(q);
            ExpId_v := f.Id;
            if f.Ide = '0' then
                ExpId_v(17 downto 0) := (others => '0');
            end if;
            check_equal(Id_v, ExpId_v, msg & ": Id");
            check_equal(Ide_v, f.Ide, msg & ": Ide");
            check_equal(Rtr_v, f.Rtr, msg & ": Rtr");
            check_equal(Dlc_v, f.Dlc, msg & ": Dlc");
            check_equal(Data_v, f.Data, msg & ": Data");
        end procedure;

        procedure checkStat (tec : natural; rec : natural; state : std_logic_vector(1 downto 0); msg : string) is
        begin
            check_equal(to_integer(unsigned(TecA)), tec, msg & ": TEC");
            check_equal(to_integer(unsigned(RecA)), rec, msg & ": REC");
            check_equal(StateA, state, msg & ": state");
        end procedure;

        -- *** Combined steps ***
        -- DUT A sends frame f, the BFM captures and acknowledges it
        procedure txAtoBfm (f : Frame_t; msg : string) is
            variable C_v    : std_logic_vector(0 to MaxBits_c - 1);
            variable Done_v : natural;
        begin
            Done_v := CntTxDoneA;
            pushTx(f);
            bfmCapture(f.NBits, f.AckIdx, C_v);
            checkBits(C_v, f.Bits, 0, f.NBits, msg & ": bus stream");
            waitCount(CntTxDoneA, Done_v + 1, msg & ": Tx_Done");
        end procedure;

        -- The BFM sends frame f, DUT A receives and acknowledges it
        procedure rxBfmToDut (f : Frame_t; msg : string; bitTime : time := BitTime_c) is
            variable C_v  : std_logic_vector(0 to MaxBits_c - 1);
            variable Rx_v : natural;
        begin
            Rx_v := CntRxA;
            bfmSendFrame(f, C_v, bitTime => bitTime);
            check_equal(C_v(f.AckIdx), '0', msg & ": acknowledge of A");
            checkBits(C_v, f.Bits, 0, f.NBits, msg & ": bus stream");
            waitCount(CntRxA, Rx_v + 1, msg & ": Rx_Valid");
            checkRx(RxQueueA_c, f, msg);
        end procedure;

        -- A bit error forced on A's frame f at recessive bit idx (A transmitting); waits for the error frame
        procedure forceBitError (f : Frame_t; idx : natural) is
            variable C_v : std_logic_vector(0 to MaxBits_c - 1);
        begin
            bfmCapture(idx + 1, -1, C_v, forceIdx => idx);
            waitRecessive(7.0);
        end procedure;

        -- The BFM sends frame f up to a stuff error at its first stuff bit
        procedure bfmStuffError (f : Frame_t) is
            variable C_v : std_logic_vector(0 to MaxBits_c - 1);
        begin
            bfmSendFrame(f, C_v, ovrIdx => f.FirstStuff, ovrVal => f.Bits(f.FirstStuff - 1), nBits => f.FirstStuff + 1);
        end procedure;

        variable Cnt_v : natural;
    begin
        test_runner_setup(runner, runner_cfg);

        while test_suite loop

            -- Reset
            Rst      <= '1';
            RstB     <= '1';
            wait for 1 us;
            wait until rising_edge(Clk);
            Rst      <= '0';
            RstB     <= '0';
            Frames_v := load_csv(output_path(runner_cfg) & "frames.csv");
            CrcErr_v := load_csv(output_path(runner_cfg) & "crcerr.csv");
            Resvd_v  := load_csv(output_path(runner_cfg) & "reserved.csv");
            Ones_v   := (others => '1');
            Zeros_v  := (others => '0');

            -- *** Reset values and integration ***
            if run("ResetValues") then
                wait until rising_edge(Clk);
                check_equal(TxReadyA, '1', "Tx_Ready");
                check_equal(CanTxA, '1', "Can_Tx");
                checkStat(0, 0, "00", "reset");
                check_equal(BusIdleA, '0', "integrating");
                waitBits(10.0);
                check_equal(BusIdleA, '0', "still integrating after 10 bits");
                waitBits(1.5);
                check_equal(BusIdleA, '1', "idle after 11 recessive bits");

            elsif run("Integration-DominantBus") then
                -- No transmission before 11 consecutive recessive bits
                BfmTx <= '0';
                F_v   := getFrame(Frames_v, 3);
                pushTx(F_v);
                waitBits(20.0);
                check_equal(BusIdleA, '0', "dominant bus: not idle");
                check_equal(CntTxDoneA, 0, "no frame");
                BfmTx <= '1';
                wait until CanBus = '1';
                T0_v  := now;
                bfmCapture(F_v.NBits, F_v.AckIdx, Capt_v);
                check(now - T0_v > BitTime_c * (10 + F_v.NBits),
                      "start of frame after the integration: " & time'image(now - T0_v - BitTime_c * F_v.NBits));
                checkBits(Capt_v, F_v.Bits, 0, F_v.NBits, "frame after integration");

            -- *** Frames (sections 3.2.1, 3.2.2 and 6) ***
            elsif run("Tx-AllFrames") then
                waitRecessive(11.5);

                for i in 0 to height(Frames_v) - 1 loop
                    txAtoBfm(getFrame(Frames_v, i), "frame " & integer'image(i));
                end loop;

                checkStat(0, 0, "00", "after the frames");

            elsif run("Rx-AllFrames") then
                waitRecessive(11.5);

                for i in 0 to height(Frames_v) - 1 loop
                    rxBfmToDut(getFrame(Frames_v, i), "frame " & integer'image(i));
                    waitBits(3.0);
                end loop;

                checkStat(0, 0, "00", "after the frames");

            elsif run("Rx-ReservedBits") then
                -- Recessive reserved bits r1 and r0: accepted by the receiver (section 3.2.1)
                waitRecessive(11.5);

                for i in 0 to 22 loop
                    rxBfmToDut(getFrame(Resvd_v, i), "frame " & integer'image(i));
                    waitBits(3.0);
                end loop;

                checkStat(0, 0, "00", "after the frames");

            elsif run("BackToBack") then
                -- Frames separated by the intermission only, alternating between A and the BFM
                waitRecessive(11.5);

                for i in 0 to 5 loop
                    F_v := getFrame(Frames_v, 36 + i);
                    G_v := getFrame(Frames_v, 50 + i);
                    pushTx(F_v);
                    bfmCapture(F_v.NBits, F_v.AckIdx, Capt_v);
                    checkBits(Capt_v, F_v.Bits, 0, F_v.NBits, "A frame " & integer'image(i));
                    waitBits(3.0);
                    rxBfmToDut(G_v, "BFM frame " & integer'image(i));
                    waitBits(3.0);
                end loop;

                check_equal(CntTxDoneA, 6, "frames of A");

            elsif run("AtoB") then
                -- DUT to DUT in both directions
                EnableB <= '1';
                waitRecessive(11.5);

                for i in 36 to 47 loop
                    F_v   := getFrame(Frames_v, i);
                    Cnt_v := CntRxB;
                    pushTx(F_v);
                    waitCount(CntRxB, Cnt_v + 1, "B receives " & integer'image(i));
                    checkRx(RxQueueB_c, F_v, "B frame " & integer'image(i));
                    waitRecessive(11.5);
                    Cnt_v := CntRxA;
                    pushTx2(F_v);
                    waitCount(CntRxA, Cnt_v + 1, "A receives " & integer'image(i));
                    checkRx(RxQueueA_c, F_v, "A frame " & integer'image(i));
                    waitRecessive(11.5);
                end loop;

                checkStat(0, 0, "00", "A after the frames");
                check_equal(to_integer(unsigned(TecB)), 0, "TEC of B");
                check_equal(to_integer(unsigned(RecB)), 0, "REC of B");

            -- *** Arbitration (section 3.2.1) ***
            elsif run("Arbitration") then
                EnableB <= '1';
                waitRecessive(11.5);

                for k in 0 to 3 loop

                    -- Pairs (winner F of B, loser G of A): identifier, standard before extended with the same base
                    -- identifier, data before remote, extended identifiers
                    case k is
                        when 0 =>
                            F_v := getFrame(Frames_v, 4);
                            G_v := getFrame(Frames_v, 26);
                        when 1 =>
                            F_v                  := getFrame(Frames_v, 4);
                            G_v                  := getFrame(Frames_v, 13);
                            G_v.Id(28 downto 18) := F_v.Id(28 downto 18);
                        when 2 =>
                            F_v     := getFrame(Frames_v, 0);
                            G_v     := getFrame(Frames_v, 0);
                            G_v.Rtr := '1';
                        when others =>
                            F_v := getFrame(Frames_v, 32);
                            G_v := getFrame(Frames_v, 33);
                    end case;

                    -- Both pending while the BFM sends a frame: both start after its intermission
                    H_v                := getFrame(Frames_v, 40);
                    Bits_v             := H_v.Bits;
                    Bits_v(H_v.AckIdx) := '1';
                    Cnt_v              := CntRxB;
                    Idx_v              := CntRxA;
                    bfmSend(Bits_v(0 to 1), 2, BitTime_c, Capt_v);
                    pushTx(G_v, blocking => false);
                    pushTx2(F_v, blocking => false);
                    bfmSend(Bits_v(2 to MaxBits_c - 1), H_v.NBits - 2, BitTime_c, Capt_v);
                    check_equal(Capt_v(H_v.AckIdx - 2), '0', "acknowledge of the BFM frame " & integer'image(k));
                    waitCount(CntRxA, Idx_v + 1, "A receives the BFM frame " & integer'image(k));
                    checkRx(RxQueueA_c, H_v, "A receives the BFM frame " & integer'image(k));
                    waitCount(CntRxB, Cnt_v + 1, "B receives the BFM frame " & integer'image(k));
                    checkRx(RxQueueB_c, H_v, "B receives the BFM frame " & integer'image(k));
                    -- Winner B: its frame on the bus unchanged (the BFM does not resynchronize: compared only if
                    -- B runs at the nominal clock), A receives it
                    Cnt_v := CntArbLostA;
                    if ClkBOffsetPpm_g = 0 then
                        bfmCapture(F_v.NBits, F_v.AckIdx, Capt_v);
                        checkBits(Capt_v, F_v.Bits, 0, F_v.NBits, "winner " & integer'image(k));
                    end if;
                    waitCount(CntArbLostA, Cnt_v + 1, "A loses " & integer'image(k));
                    waitCount(CntRxA, Idx_v + 2, "A receives the winner " & integer'image(k));
                    checkRx(RxQueueA_c, F_v, "A receives the winner " & integer'image(k));
                    -- Then the frame of A, received by B
                    Cnt_v := CntRxB;
                    waitCount(CntRxB, Cnt_v + 1, "B receives the loser " & integer'image(k));
                    checkRx(RxQueueB_c, G_v, "B receives the loser " & integer'image(k));
                    waitRecessive(11.5);
                end loop;

                check_equal(CntArbLostB, 0, "B never loses");
                check_equal(CntTxDoneA, 4, "frames of A");
                check_equal(CntTxDoneB, 4, "frames of B");

            -- *** Errors (sections 7 and 8) ***
            elsif run("Error-BitTx") then
                -- Dominant bit forced on a recessive data bit of A: error flag at the next bit, TEC + 8,
                -- retransmission after error delimiter and intermission
                waitRecessive(11.5);
                F_v   := getFrame(Frames_v, 4);
                Idx_v := findBit(F_v, 30, F_v.AckIdx - 3, '1');
                pushTx(F_v);
                bfmCapture(Idx_v + 1 + 6 + 8 + 3, -1, Capt_v, forceIdx => Idx_v);
                checkBits(Capt_v, F_v.Bits, 0, Idx_v, "bits before the error");
                checkLevel(Capt_v, Idx_v + 1, 6, '0', "active error flag");
                checkLevel(Capt_v, Idx_v + 7, 8 + 3, '1', "error delimiter and intermission");
                check_equal(CntErrBitA, 1, "Err_Bit");
                checkStat(8, 0, "00", "after the bit error");
                T0_v  := now;
                bfmCapture(F_v.NBits, F_v.AckIdx, Capt_v);
                check(now - T0_v < BitTime_c * (real(F_v.NBits) + 0.5), "retransmission right after the intermission");
                checkBits(Capt_v, F_v.Bits, 0, F_v.NBits, "retransmission");
                waitCount(CntTxDoneA, 1, "Tx_Done");
                checkStat(7, 0, "00", "after the retransmission");

            elsif run("Error-StuffRx") then
                waitRecessive(11.5);
                F_v := getFrame(Frames_v, 30);
                bfmStuffError(F_v);
                bfmSend(Ones_v, 6 + 8, BitTime_c, Capt_v);
                checkLevel(Capt_v, 0, 6, '0', "error flag of A");
                checkLevel(Capt_v, 6, 8, '1', "error delimiter");
                check_equal(CntErrStuffA, 1, "Err_Stuff");
                checkStat(0, 1, "00", "after the stuff error");
                check_equal(CntRxA, 0, "no frame");

            elsif run("Error-CrcRx") then
                waitRecessive(11.5);

                for i in 0 to 2 loop
                    F_v := getFrame(CrcErr_v, 36 + i);
                    bfmSendFrame(F_v, Capt_v, nBits => F_v.AckIdx + 2);
                    check_equal(Capt_v(F_v.AckIdx), '1', "no acknowledge on a CRC error");
                    bfmSend(Ones_v, 6 + 8, BitTime_c, Capt_v);
                    checkLevel(Capt_v, 0, 6, '0', "error flag after the ACK delimiter");
                    checkLevel(Capt_v, 6, 8, '1', "error delimiter");
                    waitBits(4.0);
                end loop;

                check_equal(CntErrCrcA, 3, "Err_Crc");
                checkStat(0, 3, "00", "after the CRC errors");
                check_equal(CntRxA, 0, "no frame");

            elsif run("Error-FormRx") then
                waitRecessive(11.5);
                F_v := getFrame(Frames_v, 5);

                -- CRC delimiter, ACK delimiter, EOF bits 1 to 6 dominant: form errors
                for k in 0 to 7 loop

                    case k is
                        when 0 => Idx_v := F_v.AckIdx - 1;
                        when 1 => Idx_v := F_v.AckIdx + 1;
                        when others => Idx_v := F_v.AckIdx + 2 + (k - 2);
                    end case;

                    bfmSendFrame(F_v, Capt_v, ovrIdx => Idx_v, ovrVal => '0', nBits => Idx_v + 1);
                    bfmSend(Ones_v, 6, BitTime_c, Capt_v);
                    checkLevel(Capt_v, 0, 6, '0', "error flag " & integer'image(k));
                    waitBits(12.0);
                end loop;

                check_equal(CntErrFormA, 8, "Err_Form");
                check_equal(CntRxA, 0, "no frame valid with an error up to the last but one EOF bit");
                -- REC: +1 per error, -1 per acknowledged reception before the error (ACK delimiter and EOF)
                checkStat(0, 1, "00", "after the form errors");
                -- Last EOF bit dominant at a receiver: no error (section 5)
                bfmSendFrame(F_v, Capt_v, ovrIdx => F_v.NBits - 1, ovrVal => '0');
                waitBits(4.0);
                check_equal(CntErrFormA, 8, "no form error on the last EOF bit");
                check_equal(CntRxA, 1, "frame valid");
                checkStat(0, 0, "00", "after the valid frame");

            elsif run("Error-AckTx") then
                -- Nobody acknowledges: ACK error, error flag at the ACK delimiter, abort during the error frame
                waitRecessive(11.5);
                F_v := getFrame(Frames_v, 2);
                pushTx(F_v);
                bfmCapture(F_v.AckIdx + 1 + 6, -1, Capt_v);
                checkBits(Capt_v, F_v.Bits, 0, F_v.AckIdx, "frame up to the ACK slot");
                check_equal(Capt_v(F_v.AckIdx), '1', "no acknowledge");
                checkLevel(Capt_v, F_v.AckIdx + 1, 6, '0', "error flag");
                check_equal(CntErrAckA, 1, "Err_Ack");
                checkStat(8, 0, "00", "after the ACK error");
                pulse(TxAbortA);
                waitCount(CntAbortedA, 1, "aborted after the attempt");
                waitBits(40.0);
                check_equal(CanTxA, '1', "no retransmission");
                check_equal(TxReadyA, '1', "ready again");

            elsif run("Error-ArbStuff") then
                -- Recessive stuff bit in the arbitration field monitored dominant: stuff error without TEC change
                -- (exception 2 of rule 3)
                waitRecessive(11.5);
                F_v := getFrame(Frames_v, 30);
                check(F_v.FirstStuff < 12, "stuff bit in the identifier");
                pushTx(F_v);
                bfmCapture(F_v.FirstStuff + 1 + 6, -1, Capt_v, forceIdx => F_v.FirstStuff);
                checkLevel(Capt_v, F_v.FirstStuff + 1, 6, '0', "error flag");
                check_equal(CntErrStuffA, 1, "Err_Stuff");
                check_equal(CntArbLostA, 0, "no arbitration loss");
                checkStat(0, 0, "00", "TEC unchanged");
                waitRecessive(7.0);
                bfmCapture(F_v.NBits, F_v.AckIdx, Capt_v);
                checkBits(Capt_v, F_v.Bits, 0, F_v.NBits, "retransmission");

            elsif run("Error-ArbLost") then
                -- Recessive identifier bit monitored dominant: arbitration lost, A receives; the bus then stays
                -- recessive, so A detects a stuff error as receiver (REC + 1) and retransmits
                waitRecessive(11.5);
                F_v   := getFrame(Frames_v, 4);
                Idx_v := findBit(F_v, 1, 11, '1');
                pushTx(F_v);
                bfmCapture(Idx_v + 1, -1, Capt_v, forceIdx => Idx_v);
                waitCount(CntArbLostA, 1, "Tx_ArbLost");
                waitCount(CntErrStuffA, 1, "stuff error of the receiver", 100 us);
                checkStat(0, 1, "00", "receiver error");
                waitRecessive(7.0);
                bfmCapture(F_v.NBits, F_v.AckIdx, Capt_v);
                checkBits(Capt_v, F_v.Bits, 0, F_v.NBits, "retransmission");
                waitCount(CntTxDoneA, 1, "Tx_Done");

            elsif run("Error-DominantBitLost") then
                -- A local receive fault (A sees recessive while it sends dominant): bit error, TEC + 8
                waitRecessive(11.5);
                F_v   := getFrame(Frames_v, 4);
                Idx_v := findBit(F_v, 14, F_v.AckIdx - 3, '0');
                pushTx(F_v);
                wait until CanBus = '0';
                forceRx(now + BitTime_c * real(Idx_v));
                waitCount(CntErrBitA, 1, "Err_Bit", 50 us);
                checkStat(8, 0, "00", "after the bit error");

            elsif run("Error-FlagBitError") then
                -- Bit error during the active error flag (A sees recessive): TEC + 8 (rule 4), new error flag
                waitRecessive(11.5);
                F_v   := getFrame(Frames_v, 4);
                Idx_v := findBit(F_v, 30, F_v.AckIdx - 3, '1');
                pushTx(F_v);
                wait until CanBus = '0';
                T0_v  := now;
                bfmCapture(Idx_v + 1, -1, Capt_v, forceIdx => Idx_v, sofTime => T0_v);
                -- A's flag runs from Idx_v + 1; its second bit seen recessive by A
                forceRx(T0_v + BitTime_c * real(Idx_v + 2));
                waitCount(CntErrBitA, 2, "Err_Bit of the flag", 50 us);
                waitRecessive(7.0);
                checkStat(16, 0, "00", "two bit errors");

            elsif run("Error-AckBitRx") then
                -- A sends its acknowledge but sees recessive (receive fault): bit error, error flag at the ACK
                -- delimiter, REC + 1 (no decrement by rule 8), no frame
                waitRecessive(11.5);
                F_v  := getFrame(Frames_v, 5);
                bfmSendFrame(F_v, Capt_v, nBits => F_v.AckIdx);
                T0_v := now; -- start of the ACK slot
                forceRx(T0_v);
                bfmCapture(6, -1, Capt_v, sofTime => T0_v + BitTime_c);
                checkLevel(Capt_v, 0, 6, '0', "error flag at the ACK delimiter");
                check_equal(CntErrBitA, 1, "Err_Bit");
                waitRecessive(7.0);
                checkStat(0, 1, "00", "receiver bit error");
                check_equal(CntRxA, 0, "no frame");

            elsif run("Error-EofTx") then
                -- Dominant last EOF bit at the transmitter: error, TEC + 8, retransmission (section 5)
                waitRecessive(11.5);
                F_v := getFrame(Frames_v, 6);
                pushTx(F_v);
                bfmCapture(F_v.NBits + 6, F_v.AckIdx, Capt_v, forceIdx => F_v.NBits - 1);
                checkLevel(Capt_v, F_v.NBits, 6, '0', "error flag after the last EOF bit");
                check_equal(CntTxDoneA, 0, "not sent");
                waitRecessive(7.0);
                checkStat(8, 0, "00", "after the EOF error");
                bfmCapture(F_v.NBits, F_v.AckIdx, Capt_v);
                checkBits(Capt_v, F_v.Bits, 0, F_v.NBits, "retransmission");
                waitCount(CntTxDoneA, 1, "Tx_Done");
                checkStat(7, 0, "00", "after the retransmission");

            -- *** Fault confinement (section 8) ***
            elsif run("Fault-RecRules") then
                waitRecessive(11.5);
                F_v := getFrame(Frames_v, 30);
                -- Rule 1: receive error REC + 1; rule 2: dominant first bit after the error flag REC + 8
                bfmStuffError(F_v);
                bfmSend(Zeros_v, 6 + 1, BitTime_c, Capt_v);
                waitBits(12.0);
                checkStat(0, 1 + 8, "00", "rules 1 and 2");
                -- Rule 6: 8 further dominant bits REC + 8
                bfmStuffError(F_v);
                bfmSend(Zeros_v, 6 + 8, BitTime_c, Capt_v);
                waitBits(12.0);
                checkStat(0, 9 + 1 + 8 + 8, "00", "rules 1, 2 and 6");
                -- Rule 6 not before the 8th dominant bit: 7 further dominant bits count for rule 2 only
                bfmStuffError(F_v);
                bfmSend(Zeros_v, 6 + 7, BitTime_c, Capt_v);
                waitBits(12.0);
                checkStat(0, 26 + 1 + 8, "00", "7 dominant bits: no rule 6");
                -- Rule 8: successful reception decrements REC
                rxBfmToDut(getFrame(Frames_v, 3), "reception");
                waitBits(3.0);
                checkStat(0, 34, "00", "rule 8");

                -- Error passive receiver (REC >= 128): passive error flag (recessive)
                for i in 0 to 12 loop
                    bfmStuffError(F_v);
                    bfmSend(Zeros_v, 6 + 1, BitTime_c, Capt_v);
                    waitBits(12.0);
                end loop;

                checkStat(0, 151, "01", "error passive");
                bfmStuffError(F_v);
                bfmSend(Ones_v, 6, BitTime_c, Capt_v);
                checkLevel(Capt_v, 0, 6, '1', "passive error flag");
                waitBits(12.0);
                checkStat(0, 152, "01", "error passive");
                -- Rule 8: REC > 127 is set to 119 by a successful reception
                rxBfmToDut(getFrame(Frames_v, 3), "reception when passive");
                waitBits(3.0);
                checkStat(0, 119, "00", "rule 8 above 127");

            elsif run("Fault-TecRule6") then
                -- Transmitter: 8 dominant bits after its error flag TEC + 8 (rule 6); no rule 2 for transmitters
                waitRecessive(11.5);
                F_v   := getFrame(Frames_v, 4);
                Idx_v := findBit(F_v, 30, F_v.AckIdx - 3, '1');
                pushTx(F_v);
                -- Bit error, error flag, then 7 dominant bits: rule 3 only
                bfmCapture(Idx_v + 1 + 13, -1, Capt_v, forceIdx => Idx_v, forceLen => 1 + 13);
                waitRecessive(7.0);
                checkStat(8, 0, "00", "7 dominant bits after the flag: no rule 6");
                -- Then 16 dominant bits: rule 3 and twice rule 6
                bfmCapture(Idx_v + 1 + 22, -1, Capt_v, forceIdx => Idx_v, forceLen => 1 + 22);
                waitRecessive(7.0);
                checkStat(32, 0, "00", "16 dominant bits after the flag: rule 6 twice");
                bfmCapture(F_v.NBits, F_v.AckIdx, Capt_v);
                checkBits(Capt_v, F_v.Bits, 0, F_v.NBits, "retransmission");
                waitCount(CntTxDoneA, 1, "Tx_Done");
                checkStat(31, 0, "00", "after the retransmission");

            elsif run("Fault-PassiveTx") then
                -- 16 bit errors: TEC 128, error passive; passive error flag; suspend transmission (8 bits)
                waitRecessive(11.5);
                F_v   := getFrame(Frames_v, 4);
                Idx_v := findBit(F_v, 30, F_v.AckIdx - 3, '1');
                pushTx(F_v);

                for k in 1 to 16 loop
                    forceBitError(F_v, Idx_v);
                end loop;

                checkStat(128, 0, "01", "error passive");
                -- Passive error flag: recessive
                bfmCapture(Idx_v + 1 + 6, -1, Capt_v, forceIdx => Idx_v);
                checkLevel(Capt_v, Idx_v + 1, 6, '1', "passive error flag");
                waitRecessive(7.0);
                checkStat(136, 0, "01", "error passive");
                -- Successful transmission, then the next frame waits for intermission and suspend transmission
                bfmCapture(F_v.NBits, F_v.AckIdx, Capt_v);
                checkBits(Capt_v, F_v.Bits, 0, F_v.NBits, "frame when passive");
                waitCount(CntTxDoneA, 1, "Tx_Done");
                checkStat(135, 0, "01", "passive after one success");
                T0_v := now;
                pushTx(F_v);
                bfmCapture(F_v.NBits, F_v.AckIdx, Capt_v);
                check(now - T0_v >= BitTime_c * (3 + 8 + F_v.NBits - 1), "suspend transmission");
                check(now - T0_v < BitTime_c * (3 + 8 + F_v.NBits + 1), "start after the suspension");

            elsif run("Fault-AckPassive") then
                -- Single node without acknowledge: error passive, but not bus off (exception 1 of rule 3)
                waitRecessive(11.5);
                F_v := getFrame(Frames_v, 1);
                pushTx(F_v);

                for k in 1 to 20 loop
                    bfmCapture(F_v.AckIdx + 1, -1, Capt_v);
                    waitRecessive(7.0);
                end loop;

                checkStat(128, 0, "01", "error passive, not bus off");
                check_equal(CntErrAckA, 20, "Err_Ack");
                -- A dominant bit during the passive error flag: TEC + 8 after all
                bfmCapture(F_v.AckIdx + 3, -1, Capt_v, forceIdx => F_v.AckIdx + 2);
                waitRecessive(7.0);
                checkStat(136, 0, "01", "exception 1 does not apply");
                pulse(TxAbortA);

            elsif run("Fault-BusOff") then
                -- 32 bit errors: TEC 256, bus off; recovery after 128 x 11 recessive bits (automatic, or after
                -- Ctrl_Recover when AutoRecover_g = false)
                waitRecessive(11.5);
                F_v   := getFrame(Frames_v, 4);
                Idx_v := findBit(F_v, 30, F_v.AckIdx - 3, '1');
                pushTx(F_v);

                for k in 1 to 31 loop
                    forceBitError(F_v, Idx_v);
                end loop;

                bfmCapture(Idx_v + 1, -1, Capt_v, forceIdx => Idx_v);
                T0_v := now; -- bus off since the sample point of the forced bit
                waitBits(0.5);
                check_equal(StateA, std_logic_vector'("11"), "bus off");
                check(to_integer(unsigned(TecA)) >= 256, "TEC >= 256");
                if not AutoRecover_g then
                    -- No recovery without a request
                    waitBits(1500.0);
                    check_equal(StateA, std_logic_vector'("11"), "still bus off without Ctrl_Recover");
                    check_equal(CanTxA, '1', "bus off: recessive");
                    pulse(RecoverA);
                    T0_v := now;
                end if;
                wait for T0_v + BitTime_c * (128 * 11 - 3) - now;
                check_equal(StateA, std_logic_vector'("11"), "bus off before 128 x 11 recessive bits");
                check_equal(CanTxA, '1', "bus off: recessive");
                -- The pending frame is sent right after the recovery
                bfmCapture(F_v.NBits, F_v.AckIdx, Capt_v);
                check(now - T0_v < BitTime_c * (128 * 11 + 2 + F_v.NBits),
                      "recovery after 128 x 11 recessive bits: " & time'image(now - T0_v - BitTime_c * F_v.NBits));
                checkBits(Capt_v, F_v.Bits, 0, F_v.NBits, "frame after the recovery");
                checkStat(0, 0, "00", "recovered");

            elsif run("Fault-BusOffDominantBits") then
                -- Recovery counts 11 consecutive recessive bits: dominant bits restart the sequence
                waitRecessive(11.5);
                F_v   := getFrame(Frames_v, 4);
                Idx_v := findBit(F_v, 30, F_v.AckIdx - 3, '1');
                pushTx(F_v);

                for k in 1 to 31 loop
                    forceBitError(F_v, Idx_v);
                end loop;

                bfmCapture(Idx_v + 1, -1, Capt_v, forceIdx => Idx_v);
                if not AutoRecover_g then
                    pulse(RecoverA);
                end if;
                -- A dominant bit after every 10 recessive bits: no complete sequence
                Bits_v     := (others => '1');
                Bits_v(10) := '0';

                for k in 1 to 150 loop
                    bfmSend(Bits_v, 11, BitTime_c, Capt_v);
                end loop;

                check_equal(StateA, std_logic_vector'("11"), "still bus off");
                -- Disabling and enabling does not bypass the recovery
                EnableA <= '0';
                waitBits(5.0);
                EnableA <= '1';
                waitBits(20.0);
                check_equal(StateA, std_logic_vector'("11"), "bus off after disabling and enabling");
                check(to_integer(unsigned(TecA)) >= 256, "TEC kept");

            -- *** Overload frames (section 3.2.4) ***
            elsif run("Overload-Intermission") then
                waitRecessive(11.5);

                for k in 0 to 1 loop
                    -- Dominant first (k = 0) or second (k = 1) bit of the intermission: overload flag of A at the
                    -- next bit; no counter change
                    F_v       := getFrame(Frames_v, 3);
                    rxBfmToDut(F_v, "frame " & integer'image(k));
                    Bits_v    := (others => '1');
                    Bits_v(k) := '0';
                    bfmSend(Bits_v, k + 1 + 6 + 8, BitTime_c, Capt_v);
                    checkLevel(Capt_v, k + 1, 6, '0', "overload flag");
                    checkLevel(Capt_v, k + 7, 8, '1', "overload delimiter");
                    waitBits(4.0);
                end loop;

                checkStat(0, 0, "00", "no counter change");

            elsif run("Overload-BitError") then
                -- Bit error during the overload flag (A sees recessive): REC + 8 (rule 5), error flag
                waitRecessive(11.5);
                F_v       := getFrame(Frames_v, 3);
                rxBfmToDut(F_v, "frame");
                T0_v      := now; -- start of the intermission
                Bits_v    := (others => '1');
                Bits_v(0) := '0';
                bfmSend(Bits_v, 1, BitTime_c, Capt_v);
                forceRx(T0_v + BitTime_c * 2.0);
                waitCount(CntErrBitA, 1, "Err_Bit", 50 us);
                waitRecessive(7.0);
                checkStat(0, 8, "00", "rule 5");

            elsif run("Overload-Delimiter") then
                -- Dominant last bit of an error delimiter: overload flag (condition 3), no counter change
                waitRecessive(11.5);
                F_v            := getFrame(Frames_v, 30);
                bfmStuffError(F_v);
                Bits_v         := (others => '1');
                Bits_v(0 to 5) := (others => '0'); -- error flag of A
                Bits_v(13)     := '0';             -- 8th bit of the error delimiter
                bfmSend(Bits_v, 14 + 6 + 8, BitTime_c, Capt_v);
                checkLevel(Capt_v, 14, 6, '0', "overload flag");
                checkLevel(Capt_v, 20, 8, '1', "overload delimiter");
                waitBits(4.0);
                checkStat(0, 1, "00", "only the stuff error counted");

            elsif run("Intermission-Sof") then
                -- Dominant third intermission bit: start of frame; a pending frame of A starts with its identifier
                waitRecessive(11.5);
                F_v  := getFrame(Frames_v, 3);
                G_v  := getFrame(Frames_v, 26); -- higher identifier than F: A loses
                pushTx(G_v);
                bfmCapture(G_v.NBits, G_v.AckIdx, Capt_v);
                T0_v := now; -- end of EOF
                waitCount(CntTxDoneA, 1, "first frame");
                pushTx(G_v);
                wait for T0_v + BitTime_c * 2 - now;
                rxBfmToDut(F_v, "frame in the third intermission bit");
                check_equal(CntArbLostA, 1, "A arbitrated without SOF");
                bfmCapture(G_v.NBits, G_v.AckIdx, Capt_v);
                checkBits(Capt_v, G_v.Bits, 0, G_v.NBits, "A after the arbitration");

            -- *** Bit timing (section 10) ***
            elsif run("Timing-Oscillator") then
                -- BFM bit time shorter and longer than nominal by the tolerance of the bit timing (frames with long
                -- runs of equal bits)
                waitRecessive(11.5);

                for s in 0 to 1 loop

                    for i in 30 to 35 loop
                        rxBfmToDut(getFrame(Frames_v, i), "tolerance " & integer'image(s) & " frame " & integer'image(i),
                                 bitTime => BitTime_c * (1.0 + (-1.0 + 2.0 * real(s)) * 0.95 * Tolerance_c));
                        waitBits(3.0);
                    end loop;

                end loop;

                checkStat(0, 0, "00", "no errors");

            elsif run("Timing-Resync") then
                -- SOF lengthened or shortened by a step of time quanta, then a single recessive-to-dominant edge
                -- (bit 2), then a stuff error at bit 8: the error flag of A starts at bit 9 of its grid, which the
                -- edge moved by sign(step) * min(|step|, SJW) time quanta (section 10, resynchronisation). Steps:
                -- early edges up to PHASE_SEG2 - 1 (after the sample point of bit 1), late edges up to SJW + 2
                -- (before the sample point of bit 2); step 0 is the reference.
                waitRecessive(11.5);
                Bits_v         := (others => '1');
                Bits_v(2)      := '0';             -- the only edge after SOF
                Bits_v(3 to 8) := (others => '1'); -- 6 recessive bits: stuff error at bit 8

                for k in -1 to (Tseg2_g - 1) + minimum(Sjw_g + 2, Tseg1_g - 1) loop
                    -- k = -1: reference with step 0; then the steps from -(PHASE_SEG2 - 1) on
                    -- BFM edges a quarter clock after the rising clock edges (no delta races, the same phase for
                    -- every step)
                    wait until rising_edge(Clk);
                    wait for ClkPeriod_c / 4;
                    T0_v  := now;
                    BfmTx <= '0';
                    if k < 0 then
                        wait for BitTime_c;
                    elsif k < Tseg2_g - 1 then
                        wait for BitTime_c - Tq_c * real(Tseg2_g - 1 - k);
                    else
                        wait for BitTime_c + Tq_c * real(k - (Tseg2_g - 1));
                    end if;
                    bfmSend(Bits_v(1 to MaxBits_c - 1), 8, BitTime_c, Capt_v);
                    bfmSend(Ones_v, 1, BitTime_c, Capt_v);
                    if CanTxA = '1' then
                        wait until CanTxA = '0' for BitTime_c * 2;
                    end if;
                    check_equal(CanTxA, '0', "error flag of A");
                    if k < 0 then
                        Ref_v := LastFallA - T0_v;
                    elsif k < Tseg2_g - 1 then
                        Idx_v := minimum(Tseg2_g - 1 - k, Sjw_g);
                        check(abs((LastFallA - T0_v) - (Ref_v - Tq_c * real(Idx_v))) < ClkPeriod_c / 2,
                              "early edge by " & integer'image(Tseg2_g - 1 - k) & " tq: flag at " &
                              time'image(LastFallA - T0_v) & ", step 0 at " & time'image(Ref_v));
                    else
                        Idx_v := minimum(k - (Tseg2_g - 1), Sjw_g);
                        check(abs((LastFallA - T0_v) - (Ref_v + Tq_c * real(Idx_v))) < ClkPeriod_c / 2,
                              "late edge by " & integer'image(k - (Tseg2_g - 1)) & " tq: flag at " &
                              time'image(LastFallA - T0_v) & ", step 0 at " & time'image(Ref_v));
                    end if;
                    waitRecessive(12.0);
                end loop;

            elsif run("Timing-SyncRules") then
                -- Synchronization rules of section 10, observed at the start of the error flag of A after a stuff
                -- error (A's bit grid). Pattern P1: SOF, 1, 0, six 1 (stuff error at bit 8, flag at bit 9).
                -- Pattern P2: SOF, 1, 0, 0, six 1 (stuff error at bit 9, flag at bit 10).
                waitRecessive(11.5);

                for k in 0 to 5 loop
                    wait until rising_edge(Clk);
                    wait for ClkPeriod_c / 4;
                    T0_v  := now;
                    BfmTx <= '0';
                    waitBits(1.0);  -- SOF
                    BfmTx <= '1';
                    waitBits(1.0);  -- bit 1
                    BfmTx <= '0';

                    case k is
                        when 0 | 1 | 5 =>
                            -- P1 (k = 0: reference); k = 1: two dominant glitches in bit 4 with phase errors of SJW
                            -- each: only the first synchronizes (rule 1, one synchronization per bit); k = 5: a dominant
                            -- glitch from SYNC_SEG of bit 4 to SJW: the recessive-to-dominant edge has phase error 0,
                            -- the dominant-to-recessive edge is not used (needs two clock cycles per time quantum)
                            waitBits(1.0); -- bit 2
                            BfmTx <= '1';
                            waitBits(1.0); -- bit 3
                            if k = 5 and Prescaler_g >= 2 then
                                wait for Tq_c / 2;
                                BfmTx <= '0';
                                wait for Tq_c * (real(Sjw_g) - 0.5);
                                BfmTx <= '1';
                                wait for BitTime_c - Tq_c * real(Sjw_g);
                            elsif k = 1 then
                                wait for Tq_c * real(Sjw_g);
                                BfmTx <= '0';
                                wait for Glitch_c;
                                BfmTx <= '1';
                                wait for Tq_c * real(Sjw_g) - Glitch_c;
                                BfmTx <= '0';
                                wait for Glitch_c;
                                BfmTx <= '1';
                                wait for BitTime_c - Tq_c * real(2 * Sjw_g) - Glitch_c;
                            else
                                waitBits(1.0);
                            end if;
                            waitBits(5.0); -- bits 5 to 8, then the bit after the error
                        when 2 =>
                            -- P1 with bit 2 lengthened by SJW: the dominant-to-recessive edge is not used
                            wait for BitTime_c + Tq_c * real(Sjw_g);
                            BfmTx <= '1';
                            waitBits(7.0);
                        when others =>
                            -- P2 (k = 3: reference); k = 4: recessive glitch in the dominant bit 3 with a
                            -- recessive-to-dominant edge at SJW: not used after the dominant sample of bit 2 (rule 2)
                            waitBits(1.0); -- bit 2
                            if k = 4 then
                                BfmTx <= '0';
                                wait for Tq_c * real(Sjw_g) - Glitch_c;
                                BfmTx <= '1';
                                wait for Glitch_c;
                                BfmTx <= '0';
                                wait for BitTime_c - Tq_c * real(Sjw_g);
                            else
                                waitBits(1.0); -- bit 3
                            end if;
                            BfmTx <= '1';
                            waitBits(7.0);
                    end case;

                    if CanTxA = '1' then
                        wait until CanTxA = '0' for BitTime_c * 2;
                    end if;
                    check_equal(CanTxA, '0', "error flag of A, case " & integer'image(k));

                    case k is
                        when 0 =>
                            Ref_v := LastFallA - T0_v;  -- P1
                        when 3 =>
                            Ref2_v := LastFallA - T0_v; -- P2
                        when 1 =>
                            check(abs((LastFallA - T0_v) - (Ref_v + Tq_c * real(Sjw_g))) < ClkPeriod_c / 2,
                                  "one synchronization per bit: flag at " & time'image(LastFallA - T0_v) &
                                  ", reference " & time'image(Ref_v));
                        when 4 =>
                            check(abs((LastFallA - T0_v) - Ref2_v) < ClkPeriod_c / 2,
                                  "no synchronization after a dominant sample: flag at " &
                                  time'image(LastFallA - T0_v) & ", reference " & time'image(Ref2_v));
                        when others =>
                            check(abs((LastFallA - T0_v) - Ref_v) < ClkPeriod_c / 2,
                                  "no synchronization on a dominant-to-recessive edge (case " & integer'image(k) &
                                  "): flag at " & time'image(LastFallA - T0_v) & ", reference " & time'image(Ref_v));
                    end case;

                    waitRecessive(12.0);
                end loop;

            elsif run("Timing-TwoClocks") then
                -- A and B with different clocks (ClkBOffsetPpm_g): frames in both directions
                EnableB <= '1';
                waitRecessive(11.5);

                for i in 30 to 41 loop
                    F_v   := getFrame(Frames_v, i);
                    Cnt_v := CntRxB;
                    pushTx(F_v);
                    waitCount(CntRxB, Cnt_v + 1, "B receives " & integer'image(i));
                    checkRx(RxQueueB_c, F_v, "B frame " & integer'image(i));
                    waitRecessive(11.5);
                    Cnt_v := CntRxA;
                    pushTx2(F_v);
                    waitCount(CntRxA, Cnt_v + 1, "A receives " & integer'image(i));
                    checkRx(RxQueueA_c, F_v, "A frame " & integer'image(i));
                    waitRecessive(11.5);
                end loop;

                checkStat(0, 0, "00", "no errors at A");
                check_equal(to_integer(unsigned(TecB)), 0, "TEC of B");
                check_equal(to_integer(unsigned(RecB)), 0, "REC of B");

            -- *** Modes ***
            elsif run("Mode-ListenOnly") then
                ListenOnlyA <= '1';
                waitRecessive(11.5);
                F_v         := getFrame(Frames_v, 6);
                Cnt_v       := CntRxA;
                bfmSendFrame(F_v, Capt_v);
                check_equal(Capt_v(F_v.AckIdx), '1', "no acknowledge");
                waitCount(CntRxA, Cnt_v + 1, "frame received");
                checkRx(RxQueueA_c, F_v, "listen only");
                waitBits(3.0);
                -- CRC error: no error flag on the bus, counters unchanged
                G_v := getFrame(CrcErr_v, 6);
                bfmSendFrame(G_v, Capt_v, nBits => G_v.AckIdx + 2);
                bfmSend(Ones_v, 6, BitTime_c, Capt_v);
                checkLevel(Capt_v, 0, 6, '1', "no error flag");
                check_equal(CntErrCrcA, 1, "CRC error detected");
                checkStat(0, 0, "00", "counters unchanged");
                -- No transmission
                pushTx(F_v);
                waitBits(200.0);
                check_equal(CntTxDoneA, 0, "no transmission");
                check(LastFallA = 0 ns, "never dominant");

            elsif run("Mode-Loopback") then
                LoopbackA <= '1';
                waitBits(12.0);

                for i in 36 to 41 loop
                    F_v   := getFrame(Frames_v, i);
                    Cnt_v := CntRxA;
                    pushTx(F_v);
                    waitCount(CntRxA, Cnt_v + 1, "own frame received");
                    checkRx(RxQueueA_c, F_v, "loopback " & integer'image(i));
                    waitCount(CntTxDoneA, i - 35, "Tx_Done");
                end loop;

                checkStat(0, 0, "00", "no errors");
                check(LastFallA = 0 ns, "bus untouched");

            -- *** Transmit control ***
            elsif run("Tx-Abort") then
                waitRecessive(11.5);
                -- Abort while A receives: dropped at once
                F_v := getFrame(Frames_v, 3);
                G_v := getFrame(Frames_v, 26);
                bfmSendFrame(F_v, Capt_v, nBits => 3);
                pushTx(G_v);
                pulse(TxAbortA);
                waitCount(CntAbortedA, 1, "aborted");
                waitRecessive(11.5);
                -- Abort during a successful transmission: sent
                pushTx(F_v);
                wait until CanBus = '0';
                T0_v := now;
                pulse(TxAbortA);
                bfmCapture(F_v.NBits, F_v.AckIdx, Capt_v, sofTime => T0_v);
                waitCount(CntTxDoneA, 1, "Tx_Done");
                check_equal(CntAbortedA, 1, "not aborted");
                waitRecessive(11.5);
                -- Abort during a failing transmission (no acknowledge): dropped
                pushTx(F_v);
                wait until CanBus = '0';
                T0_v := now;
                pulse(TxAbortA);
                bfmCapture(F_v.AckIdx + 1 + 6, -1, Capt_v, sofTime => T0_v);
                waitCount(CntAbortedA, 2, "aborted after the failed attempt");
                waitBits(40.0);
                check_equal(CntTxDoneA, 1, "no retransmission");
                check_equal(TxReadyA, '1', "ready");

            elsif run("Disable") then
                waitRecessive(11.5);
                EnableA <= '0';
                F_v     := getFrame(Frames_v, 3);
                pushTx(F_v);
                waitBits(50.0);
                check_equal(CanTxA, '1', "disabled: recessive");
                check_equal(BusIdleA, '0', "disabled: not idle");
                EnableA <= '1';
                T0_v    := now;
                bfmCapture(F_v.NBits, F_v.AckIdx, Capt_v);
                check(now - T0_v >= BitTime_c * (11 + F_v.NBits),
                      "integration after enabling: " & time'image(now - T0_v - BitTime_c * F_v.NBits));
                checkBits(Capt_v, F_v.Bits, 0, F_v.NBits, "frame after enabling");

            end if;

            -- Idle bus at the end of every test
            BfmTx <= '1';
            wait for 10 us;
        end loop;

        test_runner_cleanup(runner);
    end process;

    -----------------------------------------------------------------------------------------------
    -- Clocks and Bus
    -----------------------------------------------------------------------------------------------
    Clk  <= not Clk after 0.5 * ClkPeriod_c;
    ClkB <= not ClkB after 0.5 * ClkBPeriod_c;

    CanBus  <= CanTxA and CanTxB and BfmTx;
    BusDelA <= transport CanBus after LoopDelay_c;
    CanRxA  <= '1' when RxForceA = '1' else BusDelA;
    CanRxB  <= transport CanBus after LoopDelay_c;

    -----------------------------------------------------------------------------------------------
    -- Transmit requests
    -----------------------------------------------------------------------------------------------
    p_push_a : process is
    begin
        wait on PushReqA;

        while PushAckA < PushReqA loop
            if TxReadyA /= '1' then
                wait until TxReadyA = '1';
            end if;
            wait until rising_edge(Clk);
            TxValidA <= '1';
            TxIdA    <= PushFrameA.Id;
            TxIdeA   <= PushFrameA.Ide;
            TxRtrA   <= PushFrameA.Rtr;
            TxDlcA   <= PushFrameA.Dlc;
            TxDataA  <= PushFrameA.Data;
            wait until rising_edge(Clk);
            TxValidA <= '0';
            PushAckA <= PushAckA + 1;
            wait for 0 ns;
        end loop;

    end process;

    p_push_b : process is
    begin
        wait on PushReqB;

        while PushAckB < PushReqB loop
            if TxReadyB /= '1' then
                wait until TxReadyB = '1';
            end if;
            wait until rising_edge(ClkB);
            TxValidB <= '1';
            TxIdB    <= PushFrameB.Id;
            TxIdeB   <= PushFrameB.Ide;
            TxRtrB   <= PushFrameB.Rtr;
            TxDlcB   <= PushFrameB.Dlc;
            TxDataB  <= PushFrameB.Data;
            wait until rising_edge(ClkB);
            TxValidB <= '0';
            PushAckB <= PushAckB + 1;
            wait for 0 ns;
        end loop;

    end process;

    -----------------------------------------------------------------------------------------------
    -- Monitors
    -----------------------------------------------------------------------------------------------
    p_fall_a : process (CanTxA) is
    begin
        if falling_edge(CanTxA) then
            LastFallA <= now;
        end if;
    end process;

    p_mon_a : process (Clk) is
    begin
        if rising_edge(Clk) then
            if RxValidA = '1' then
                CntRxA <= CntRxA + 1;
                push(RxQueueA_c, RxIdA);
                push(RxQueueA_c, RxIdeA);
                push(RxQueueA_c, RxRtrA);
                push(RxQueueA_c, RxDlcA);
                push(RxQueueA_c, RxDataA);
            end if;
            if TxDoneA = '1' then
                CntTxDoneA <= CntTxDoneA + 1;
            end if;
            if TxAbortedA = '1' then
                CntAbortedA <= CntAbortedA + 1;
            end if;
            if TxArbLostA = '1' then
                CntArbLostA <= CntArbLostA + 1;
            end if;
            if ErrBitA = '1' then
                CntErrBitA <= CntErrBitA + 1;
            end if;
            if ErrStuffA = '1' then
                CntErrStuffA <= CntErrStuffA + 1;
            end if;
            if ErrCrcA = '1' then
                CntErrCrcA <= CntErrCrcA + 1;
            end if;
            if ErrFormA = '1' then
                CntErrFormA <= CntErrFormA + 1;
            end if;
            if ErrAckA = '1' then
                CntErrAckA <= CntErrAckA + 1;
            end if;
        end if;
    end process;

    p_mon_b : process (ClkB) is
    begin
        if rising_edge(ClkB) then
            if RxValidB = '1' then
                CntRxB <= CntRxB + 1;
                push(RxQueueB_c, RxIdB);
                push(RxQueueB_c, RxIdeB);
                push(RxQueueB_c, RxRtrB);
                push(RxQueueB_c, RxDlcB);
                push(RxQueueB_c, RxDataB);
            end if;
            if TxDoneB = '1' then
                CntTxDoneB <= CntTxDoneB + 1;
            end if;
            if TxArbLostB = '1' then
                CntArbLostB <= CntArbLostB + 1;
            end if;
        end if;
    end process;

    -----------------------------------------------------------------------------------------------
    -- DUTs
    -----------------------------------------------------------------------------------------------
    i_dut_a : entity olo.olo_intf_can
        generic map (
            SyncTmr_g     => SyncTmr_g,
            AutoRecover_g => AutoRecover_g
        )
        port map (
            Clk            => Clk,
            Rst            => Rst,
            Cfg_Enable     => EnableA,
            Cfg_Prescaler  => Prescaler_c,
            Cfg_Tseg1      => Tseg1_c,
            Cfg_Tseg2      => Tseg2_c,
            Cfg_Sjw        => Sjw_c,
            Cfg_ListenOnly => ListenOnlyA,
            Cfg_Loopback   => LoopbackA,
            Ctrl_Recover   => RecoverA,
            Tx_Valid       => TxValidA,
            Tx_Ready       => TxReadyA,
            Tx_Id          => TxIdA,
            Tx_Ide         => TxIdeA,
            Tx_Rtr         => TxRtrA,
            Tx_Dlc         => TxDlcA,
            Tx_Data        => TxDataA,
            Tx_Abort       => TxAbortA,
            Tx_Done        => TxDoneA,
            Tx_Aborted     => TxAbortedA,
            Tx_ArbLost     => TxArbLostA,
            Rx_Valid       => RxValidA,
            Rx_Id          => RxIdA,
            Rx_Ide         => RxIdeA,
            Rx_Rtr         => RxRtrA,
            Rx_Dlc         => RxDlcA,
            Rx_Data        => RxDataA,
            Stat_Tec       => TecA,
            Stat_Rec       => RecA,
            Stat_State     => StateA,
            Stat_BusIdle   => BusIdleA,
            Err_Bit        => ErrBitA,
            Err_Stuff      => ErrStuffA,
            Err_Crc        => ErrCrcA,
            Err_Form       => ErrFormA,
            Err_Ack        => ErrAckA,
            Can_Tx         => CanTxA,
            Can_Rx         => CanRxA
        );

    i_dut_b : entity olo.olo_intf_can
        port map (
            Clk           => ClkB,
            Rst           => RstB,
            Cfg_Enable    => EnableB,
            Cfg_Prescaler => Prescaler_c,
            Cfg_Tseg1     => Tseg1_c,
            Cfg_Tseg2     => Tseg2_c,
            Cfg_Sjw       => Sjw_c,
            Tx_Valid      => TxValidB,
            Tx_Ready      => TxReadyB,
            Tx_Id         => TxIdB,
            Tx_Ide        => TxIdeB,
            Tx_Rtr        => TxRtrB,
            Tx_Dlc        => TxDlcB,
            Tx_Data       => TxDataB,
            Tx_Done       => TxDoneB,
            Tx_ArbLost    => TxArbLostB,
            Rx_Valid      => RxValidB,
            Rx_Id         => RxIdB,
            Rx_Ide        => RxIdeB,
            Rx_Rtr        => RxRtrB,
            Rx_Dlc        => RxDlcB,
            Rx_Data       => RxDataB,
            Stat_Tec      => TecB,
            Stat_Rec      => RecB,
            Can_Tx        => CanTxB,
            Can_Rx        => CanRxB
        );

end architecture;
