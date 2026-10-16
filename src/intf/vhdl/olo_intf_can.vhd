---------------------------------------------------------------------------------------------------
-- Copyright (c) 2026 by Julian Schneider
-- Authors: Julian Schneider
---------------------------------------------------------------------------------------------------

---------------------------------------------------------------------------------------------------
-- Description
---------------------------------------------------------------------------------------------------
-- CAN 2.0B protocol controller (standard and extended frames, error handling, fault confinement and
-- bit timing). Frames are sent and received as one beat each; the CAN bus is connected through a
-- transceiver (Can_Tx/Can_Rx, '1' = recessive).
--
-- Documentation:
-- https://github.com/open-logic/open-logic/blob/main/doc/intf/olo_intf_can.md
--
-- Note: The link points to the documentation of the latest release. If you
--       use an older version, the documentation might not match the code.

---------------------------------------------------------------------------------------------------
-- Libraries
---------------------------------------------------------------------------------------------------
library ieee;
    use ieee.std_logic_1164.all;
    use ieee.numeric_std.all;

library work;
    use work.olo_base_pkg_logic.all;

---------------------------------------------------------------------------------------------------
-- Entity
---------------------------------------------------------------------------------------------------
entity olo_intf_can is
    generic (
        SyncStages_g    : positive range 2 to 4 := 2;
        SyncTmr_g       : boolean               := false;
        AutoRecover_g   : boolean               := true
    );
    port (
        -- Control Signals
        Clk             : in    std_logic;
        Rst             : in    std_logic;
        -- Configuration (static while Cfg_Enable = '1')
        Cfg_Enable      : in    std_logic                     := '1';
        Cfg_Prescaler   : in    std_logic_vector(9 downto 0);
        Cfg_Tseg1       : in    std_logic_vector(4 downto 0);
        Cfg_Tseg2       : in    std_logic_vector(3 downto 0);
        Cfg_Sjw         : in    std_logic_vector(2 downto 0);
        Cfg_ListenOnly  : in    std_logic                     := '0';
        Cfg_Loopback    : in    std_logic                     := '0';
        -- Control
        Ctrl_Recover    : in    std_logic                     := '0';
        -- Transmit Frame
        Tx_Valid        : in    std_logic                     := '0';
        Tx_Ready        : out   std_logic;
        Tx_Id           : in    std_logic_vector(28 downto 0) := (others => '0');
        Tx_Ide          : in    std_logic                     := '0';
        Tx_Rtr          : in    std_logic                     := '0';
        Tx_Dlc          : in    std_logic_vector(3 downto 0)  := (others => '0');
        Tx_Data         : in    std_logic_vector(63 downto 0) := (others => '0');
        Tx_Abort        : in    std_logic                     := '0';
        Tx_Done         : out   std_logic;
        Tx_Aborted      : out   std_logic;
        Tx_ArbLost      : out   std_logic;
        -- Receive Frame
        Rx_Valid        : out   std_logic;
        Rx_Id           : out   std_logic_vector(28 downto 0);
        Rx_Ide          : out   std_logic;
        Rx_Rtr          : out   std_logic;
        Rx_Dlc          : out   std_logic_vector(3 downto 0);
        Rx_Data         : out   std_logic_vector(63 downto 0);
        -- Status
        Stat_Tec        : out   std_logic_vector(8 downto 0);
        Stat_Rec        : out   std_logic_vector(7 downto 0);
        Stat_State      : out   std_logic_vector(1 downto 0);
        Stat_BusIdle    : out   std_logic;
        -- Error Events
        Err_Bit         : out   std_logic;
        Err_Stuff       : out   std_logic;
        Err_Crc         : out   std_logic;
        Err_Form        : out   std_logic;
        Err_Ack         : out   std_logic;
        -- CAN Interface
        Can_Tx          : out   std_logic;
        Can_Rx          : in    std_logic                     := '1'
    );
end entity;

---------------------------------------------------------------------------------------------------
-- Architecture
---------------------------------------------------------------------------------------------------
architecture rtl of olo_intf_can is

    -- *** Constants ***
    constant CrcPolynomial_c : std_logic_vector(14 downto 0) := "100010110011001"; -- 0x4599
    constant Dominant_c      : std_logic                     := '0';
    constant Recessive_c     : std_logic                     := '1';

    -- *** Types ***
    -- Field of the bit on the bus (the bit sampled at the next sample point)
    type Fsm_t is (
        Integrating_s, Idle_s, Id_s, SrrRtr_s, Ide_s, IdExt_s, RtrExt_s, R1_s, R0_s, Dlc_s, Data_s, Crc_s,
        CrcDel_s, AckSlot_s, AckDel_s, Eof_s, Intermission_s, Suspend_s, ErrFlag_s, OvlFlag_s, DelimWait_s,
        Delim_s, BusOff_s
    );

    type TwoProcess_r is record
        -- Bit timing
        PrescCnt    : unsigned(9 downto 0);
        TqCnt       : unsigned(5 downto 0);
        Lengthen    : unsigned(2 downto 0);
        Shorten     : unsigned(2 downto 0);
        SyncDone    : std_logic;
        RxPrev      : std_logic;
        LastSample  : std_logic;
        CanTxInt    : std_logic;
        CanTx       : std_logic;
        -- Bit stream
        Fsm         : Fsm_t;
        BitCnt      : unsigned(5 downto 0);
        TxBit       : std_logic;
        Monitor     : std_logic;
        InArb       : std_logic;
        StuffNext   : std_logic;
        StuffCnt    : unsigned(2 downto 0);
        StuffLast   : std_logic;
        Crc         : std_logic_vector(14 downto 0);
        CrcErr      : std_logic;
        IsTx        : std_logic;
        DataBits    : unsigned(6 downto 0);
        -- Receive frame
        RxIdBase    : std_logic_vector(10 downto 0);
        RxIdExt     : std_logic_vector(17 downto 0);
        RxSrrRtr    : std_logic;
        RxIde       : std_logic;
        RxRtr       : std_logic;
        RxDlc       : std_logic_vector(3 downto 0);
        RxData      : std_logic_vector(63 downto 0);
        -- Transmit frame
        TxPending   : std_logic;
        TxAbortReq  : std_logic;
        TxId        : std_logic_vector(28 downto 0);
        TxIde       : std_logic;
        TxRtr       : std_logic;
        TxDlc       : std_logic_vector(3 downto 0);
        TxData      : std_logic_vector(63 downto 0);
        -- Error and overload flags
        FlagActive  : std_logic;
        FlagIsError : std_logic;
        EqCnt       : unsigned(2 downto 0);
        EqVal       : std_logic;
        DomCnt      : unsigned(2 downto 0);
        FirstAfter  : std_logic;
        AckErrPass  : std_logic;
        -- Fault confinement
        Tec         : unsigned(8 downto 0);
        Rec         : unsigned(7 downto 0);
        BusOff      : std_logic;
        RecessCnt   : unsigned(3 downto 0);
        SeqCnt      : unsigned(7 downto 0);
        RecoverReq  : std_logic;
        -- Output events
        RxValid     : std_logic;
        TxDone      : std_logic;
        TxAborted   : std_logic;
        TxArbLost   : std_logic;
        ErrBit      : std_logic;
        ErrStuff    : std_logic;
        ErrCrc      : std_logic;
        ErrForm     : std_logic;
        ErrAck      : std_logic;
    end record;

    signal r, r_next : TwoProcess_r;

    signal RxSync : std_logic;

    -- *** Helpers ***
    function isPassive (v : TwoProcess_r) return boolean is
    begin
        return v.Tec >= 128 or v.Rec >= 128;
    end function;

    function isFrameField (f : Fsm_t) return boolean is
    begin

        case f is
            when Id_s | SrrRtr_s | Ide_s | IdExt_s | RtrExt_s | R1_s | R0_s | Dlc_s | Data_s | Crc_s |
                 CrcDel_s | AckSlot_s | AckDel_s | Eof_s => return true;
            when others => return false;
        end case;

    end function;

    -- Error counter increments (saturating), not applied in listen-only mode
    procedure incCounters (
        variable v : inout TwoProcess_r;
        TecInc     : in natural;
        RecInc     : in natural;
        ListenOnly : in std_logic) is
    begin
        if ListenOnly = '0' then
            if to_integer(v.Tec) + TecInc > 511 then
                v.Tec := (others => '1');
            else
                v.Tec := v.Tec + TecInc;
            end if;
            if to_integer(v.Rec) + RecInc > 255 then
                v.Rec := (others => '1');
            else
                v.Rec := v.Rec + RecInc;
            end if;
        end if;
    end procedure;

    -- Start of an error flag at the next bit (the flag type follows the state before the increments)
    procedure startErrorFlag (
        variable v : inout TwoProcess_r;
        TecInc     : in natural;
        RecInc     : in natural;
        ListenOnly : in std_logic) is
        variable Active_v : boolean;
    begin
        Active_v      := not isPassive(v) and ListenOnly = '0';
        incCounters(v, TecInc, RecInc, ListenOnly);
        v.Fsm         := ErrFlag_s;
        v.BitCnt      := (others => '0');
        v.FlagIsError := '1';
        v.EqCnt       := (others => '0');
        v.StuffNext   := '0';
        v.InArb       := '0';
        if Active_v then
            v.FlagActive := '1';
            v.TxBit      := Dominant_c;
            v.Monitor    := '1';
        else
            v.FlagActive := '0';
            v.TxBit      := Recessive_c;
            v.Monitor    := '0';
        end if;
        -- A failed attempt of an aborted frame drops the frame
        if v.IsTx = '1' and v.TxAbortReq = '1' then
            v.TxPending  := '0';
            v.TxAbortReq := '0';
            v.TxAborted  := '1';
        end if;
        -- Bus off (the node is error passive before, so the flag would be recessive anyway)
        if v.Tec >= 256 then
            v.Fsm        := BusOff_s;
            v.BusOff     := '1';
            v.IsTx       := '0';
            v.TxBit      := Recessive_c;
            v.Monitor    := '0';
            v.RecessCnt  := (others => '0');
            v.SeqCnt     := (others => '0');
            v.RecoverReq := '0';
        end if;
    end procedure;

    -- Start of an overload flag at the next bit
    procedure startOverloadFlag (
        variable v : inout TwoProcess_r;
        ListenOnly : in std_logic) is
    begin
        v.Fsm         := OvlFlag_s;
        v.BitCnt      := (others => '0');
        v.FlagIsError := '0';
        v.FlagActive  := not ListenOnly;
        v.TxBit       := ListenOnly; -- dominant unless listen-only
        v.Monitor     := not ListenOnly;
    end procedure;

    -- Start of frame (SOF sampled): the next bit is the first identifier bit
    procedure startFrame (
        variable v : inout TwoProcess_r) is
    begin
        v.Fsm       := Id_s;
        v.BitCnt    := (others => '0');
        v.Crc       := (others => '0'); -- SOF is a 0, the CRC stays 0
        v.CrcErr    := '0';
        v.StuffCnt  := to_unsigned(1, v.StuffCnt'length);
        v.StuffLast := Dominant_c;
        v.StuffNext := '0';
        v.RxIdExt   := (others => '0');
        v.RxData    := (others => '0');
    end procedure;

begin

    -----------------------------------------------------------------------------------------------
    -- Combinatorial Process
    -----------------------------------------------------------------------------------------------
    p_comb : process (all) is
        variable v           : TwoProcess_r;
        variable RxBus_v     : std_logic;
        variable Edge_v      : boolean;
        variable HardSync_v  : boolean;
        variable Sample_v    : boolean;
        variable BitStart_v  : boolean;
        variable Prescaler_v : unsigned(9 downto 0);
        variable Tseg1_v     : unsigned(5 downto 0);
        variable Tseg2_v     : unsigned(5 downto 0);
        variable Sjw_v       : unsigned(5 downto 0);
        variable SampleTq_v  : unsigned(5 downto 0);
        variable LastTq_v    : unsigned(5 downto 0);
        variable PhaseErr_v  : unsigned(5 downto 0);
        variable Bit_v       : std_logic;
        variable Handled_v   : boolean;
        variable CrcNxt_v    : std_logic;
        variable MayTx_v     : boolean;
    begin
        -- *** Hold variables stable ***
        v := r;

        -- *** Default values of the events ***
        v.RxValid   := '0';
        v.TxDone    := '0';
        v.TxAborted := '0';
        v.TxArbLost := '0';
        v.ErrBit    := '0';
        v.ErrStuff  := '0';
        v.ErrCrc    := '0';
        v.ErrForm   := '0';
        v.ErrAck    := '0';

        -- *** Transmit frame interface ***
        if Tx_Valid = '1' and r.TxPending = '0' then
            v.TxPending  := '1';
            v.TxAbortReq := '0';
            v.TxId       := Tx_Id;
            v.TxIde      := Tx_Ide;
            v.TxRtr      := Tx_Rtr;
            v.TxDlc      := Tx_Dlc;
            v.TxData     := Tx_Data;
        end if;
        if Tx_Abort = '1' and r.TxPending = '1' then
            if r.IsTx = '1' then
                -- Frame on the bus: dropped after a failed attempt, kept on success
                v.TxAbortReq := '1';
            else
                v.TxPending  := '0';
                v.TxAbortReq := '0';
                v.TxAborted  := '1';
            end if;
        end if;

        -- *** Bus-off recovery request ***
        if Ctrl_Recover = '1' and r.BusOff = '1' then
            v.RecoverReq := '1';
        end if;

        -- *** Bit timing ***
        -- Bus value: the own transmit bit in loopback mode
        if Cfg_Loopback = '1' then
            RxBus_v := r.CanTxInt;
        else
            RxBus_v := RxSync;
        end if;
        Edge_v   := r.RxPrev = Recessive_c and RxBus_v = Dominant_c; -- only recessive to dominant edges
        v.RxPrev := RxBus_v;

        Prescaler_v := unsigned(Cfg_Prescaler);
        if Prescaler_v = 0 then
            Prescaler_v := to_unsigned(1, Prescaler_v'length);
        end if;
        Tseg1_v := resize(unsigned(Cfg_Tseg1), Tseg1_v'length);
        Tseg2_v := resize(unsigned(Cfg_Tseg2), Tseg2_v'length);
        Sjw_v   := resize(unsigned(Cfg_Sjw), Sjw_v'length);

        Sample_v   := false;
        BitStart_v := false;
        HardSync_v := r.Fsm = Idle_s or r.Fsm = Integrating_s or r.Fsm = Suspend_s or r.Fsm = BusOff_s;

        -- Synchronisation (Bosch 2.0 part B section 10): one per bit, only after a recessive sample
        if Edge_v and r.SyncDone = '0' and r.LastSample = Recessive_c and Cfg_Enable = '1' then
            SampleTq_v := Tseg1_v + v.Lengthen;
            LastTq_v   := SampleTq_v + Tseg2_v - v.Shorten;
            if HardSync_v then
                -- Hard synchronisation: the bit time restarts with SYNC_SEG at the edge
                v.PrescCnt := (others => '0');
                v.TqCnt    := (others => '0');
                v.Lengthen := (others => '0');
                v.Shorten  := (others => '0');
                v.SyncDone := '1';
                BitStart_v := true;
            elsif r.TqCnt = 0 then
                -- Edge within SYNC_SEG: phase error 0
                null;
            elsif r.TqCnt <= SampleTq_v then
                -- Positive phase error (edge before the sample point): lengthen PHASE_SEG1; not while
                -- the node transmits a dominant bit (rule 4)
                if r.CanTxInt = Recessive_c then
                    PhaseErr_v := r.TqCnt;
                    if PhaseErr_v <= Sjw_v then
                        -- Same as a hard synchronisation (the same bit restarts)
                        v.PrescCnt := (others => '0');
                        v.TqCnt    := (others => '0');
                        v.Lengthen := (others => '0');
                    else
                        v.Lengthen := resize(Sjw_v, v.Lengthen'length);
                    end if;
                    v.SyncDone := '1';
                end if;
            else
                -- Negative phase error (edge after the sample point): shorten PHASE_SEG2
                PhaseErr_v := LastTq_v - r.TqCnt + 1;
                if PhaseErr_v <= Sjw_v then
                    -- Same as a hard synchronisation (the next bit starts at the edge)
                    v.PrescCnt := (others => '0');
                    v.TqCnt    := (others => '0');
                    v.Lengthen := (others => '0');
                    v.Shorten  := (others => '0');
                    BitStart_v := true;
                else
                    v.Shorten := resize(Sjw_v, v.Shorten'length);
                end if;
                v.SyncDone := '1';
            end if;
        end if;

        -- Time quanta and segments
        SampleTq_v := Tseg1_v + v.Lengthen;
        LastTq_v   := SampleTq_v + Tseg2_v - v.Shorten;
        if v.PrescCnt >= Prescaler_v - 1 then
            v.PrescCnt := (others => '0');
            if v.TqCnt = SampleTq_v then
                Sample_v := true;
            end if;
            if v.TqCnt >= LastTq_v then
                v.TqCnt    := (others => '0');
                v.Lengthen := (others => '0');
                v.Shorten  := (others => '0');
                BitStart_v := true;
            else
                v.TqCnt := v.TqCnt + 1;
            end if;
        else
            v.PrescCnt := v.PrescCnt + 1;
        end if;

        if Cfg_Enable = '0' then
            Sample_v   := false;
            BitStart_v := false;
        end if;
        if Sample_v then
            v.SyncDone   := '0';
            v.LastSample := RxBus_v;
        end if;

        -- *** Bit stream processing at the sample point ***
        if Sample_v then
            Bit_v     := RxBus_v;
            Handled_v := false;
            MayTx_v   := r.TxPending = '1' and r.TxAbortReq = '0' and Cfg_ListenOnly = '0';

            -- Bit monitoring of the frame bits the node sends (Bosch 2.0 part B section 7.1)
            if r.Monitor = '1' and Bit_v /= r.TxBit and (isFrameField(r.Fsm) or r.Fsm = Idle_s) then
                Handled_v := true;
                if r.StuffNext = '1' and r.InArb = '1' and r.TxBit = Recessive_c then
                    -- Stuff error on a recessive stuff bit in the arbitration field: no TEC change
                    -- (exception 2 of section 8 rule 3)
                    v.ErrStuff := '1';
                    startErrorFlag(v, 0, 0, Cfg_ListenOnly);
                elsif r.StuffNext = '0' and r.InArb = '1' and r.TxBit = Recessive_c then
                    -- Arbitration lost: continue as receiver, the frame stays pending
                    Handled_v   := false;
                    v.IsTx      := '0';
                    v.Monitor   := '0';
                    v.TxArbLost := '1';
                    if r.TxAbortReq = '1' then
                        v.TxPending  := '0';
                        v.TxAbortReq := '0';
                        v.TxAborted  := '1';
                    end if;
                elsif r.Fsm = AckSlot_s and r.IsTx = '1' and r.TxBit = Recessive_c then
                    -- Dominant acknowledge on the recessive ACK slot of the transmitter
                    Handled_v := false;
                elsif r.IsTx = '1' then
                    v.ErrBit := '1';
                    startErrorFlag(v, 8, 0, Cfg_ListenOnly);
                else
                    -- Receiver sending the acknowledge
                    v.ErrBit := '1';
                    startErrorFlag(v, 0, 1, Cfg_ListenOnly);
                end if;
            end if;

            -- Stuff bits (from SOF to the end of the CRC sequence)
            if not Handled_v and r.StuffNext = '1' and isFrameField(r.Fsm) then
                Handled_v := true;
                if Bit_v = r.StuffLast then
                    v.ErrStuff := '1';
                    if v.IsTx = '1' then
                        startErrorFlag(v, 8, 0, Cfg_ListenOnly);
                    else
                        startErrorFlag(v, 0, 1, Cfg_ListenOnly);
                    end if;
                else
                    v.StuffNext := '0';
                    v.StuffCnt  := to_unsigned(1, v.StuffCnt'length);
                    v.StuffLast := Bit_v;
                end if;
            end if;

            if not Handled_v then

                -- Stuff counting of the data bits of the stuffed fields
                case r.Fsm is
                    when Id_s | SrrRtr_s | Ide_s | IdExt_s | RtrExt_s | R1_s | R0_s | Dlc_s | Data_s | Crc_s =>
                        if Bit_v = r.StuffLast then
                            v.StuffCnt := r.StuffCnt + 1;
                        else
                            v.StuffCnt  := to_unsigned(1, v.StuffCnt'length);
                            v.StuffLast := Bit_v;
                        end if;
                        if v.StuffCnt = 5 then
                            v.StuffNext := '1';
                        end if;
                        -- CRC over SOF, arbitration, control and data field
                        if r.Fsm /= Crc_s then
                            CrcNxt_v := Bit_v xor r.Crc(14);
                            v.Crc    := r.Crc(13 downto 0) & '0';
                            if CrcNxt_v = '1' then
                                v.Crc := v.Crc xor CrcPolynomial_c;
                            end if;
                        end if;
                    when others => null;
                end case;

                case r.Fsm is

                    -- *** Bus integration and idle ***
                    when Integrating_s =>
                        if Bit_v = Recessive_c then
                            if r.RecessCnt = 10 then
                                v.RecessCnt := (others => '0');
                                v.Fsm       := Idle_s;
                            else
                                v.RecessCnt := r.RecessCnt + 1;
                            end if;
                        else
                            v.RecessCnt := (others => '0');
                        end if;

                    when Idle_s =>
                        if Bit_v = Dominant_c then
                            -- Start of frame (own or of another node)
                            startFrame(v);
                        end if;

                    -- *** Arbitration and control field ***
                    when Id_s =>
                        v.RxIdBase(10 - to_integer(r.BitCnt)) := Bit_v;
                        if r.BitCnt = 10 then
                            v.Fsm    := SrrRtr_s;
                            v.BitCnt := (others => '0');
                        else
                            v.BitCnt := r.BitCnt + 1;
                        end if;

                    when SrrRtr_s =>
                        v.RxSrrRtr := Bit_v;
                        v.Fsm      := Ide_s;

                    when Ide_s =>
                        v.RxIde := Bit_v;
                        if Bit_v = Dominant_c then
                            -- Standard format: the previous bit was RTR
                            v.RxRtr := r.RxSrrRtr;
                            v.Fsm   := R0_s;
                        else
                            v.Fsm := IdExt_s;
                        end if;

                    when IdExt_s =>
                        v.RxIdExt(17 - to_integer(r.BitCnt)) := Bit_v;
                        if r.BitCnt = 17 then
                            v.Fsm    := RtrExt_s;
                            v.BitCnt := (others => '0');
                        else
                            v.BitCnt := r.BitCnt + 1;
                        end if;

                    when RtrExt_s =>
                        v.RxRtr := Bit_v;
                        v.Fsm   := R1_s;

                    when R1_s =>
                        v.Fsm := R0_s;

                    when R0_s =>
                        v.Fsm    := Dlc_s;
                        v.BitCnt := (others => '0');

                    when Dlc_s =>
                        v.RxDlc(3 - to_integer(r.BitCnt)) := Bit_v;
                        if r.BitCnt = 3 then
                            v.BitCnt := (others => '0');
                            -- Data field: 0 to 8 bytes (DLC 9 to 15 mean 8 bytes), none in a remote frame
                            if r.RxRtr = Recessive_c or (r.RxDlc(3 downto 1) = "000" and Bit_v = '0') then
                                v.DataBits := (others => '0');
                                v.Fsm      := Crc_s;
                            else
                                if r.RxDlc(3) = '1' then
                                    v.DataBits := to_unsigned(64, v.DataBits'length);
                                else
                                    v.DataBits := resize(unsigned(r.RxDlc(2 downto 1) & Bit_v) & "000", v.DataBits'length);
                                end if;
                                v.Fsm := Data_s;
                            end if;
                        else
                            v.BitCnt := r.BitCnt + 1;
                        end if;

                    when Data_s =>
                        v.RxData(63 - to_integer(r.BitCnt)) := Bit_v;
                        if r.BitCnt = r.DataBits - 1 then
                            v.Fsm    := Crc_s;
                            v.BitCnt := (others => '0');
                        else
                            v.BitCnt := r.BitCnt + 1;
                        end if;

                    -- *** CRC, acknowledge and end of frame ***
                    when Crc_s =>
                        if Bit_v /= r.Crc(14 - to_integer(r.BitCnt)) then
                            v.CrcErr := '1';
                        end if;
                        if r.BitCnt = 14 then
                            v.Fsm := CrcDel_s;
                        else
                            v.BitCnt := r.BitCnt + 1;
                        end if;

                    when CrcDel_s =>
                        if Bit_v = Dominant_c then
                            v.ErrForm := '1';
                            if r.IsTx = '1' then
                                startErrorFlag(v, 8, 0, Cfg_ListenOnly);
                            else
                                startErrorFlag(v, 0, 1, Cfg_ListenOnly);
                            end if;
                        else
                            v.Fsm := AckSlot_s;
                        end if;

                    when AckSlot_s =>
                        if r.IsTx = '1' then
                            if Bit_v = Recessive_c then
                                -- Acknowledgment error; exception 1 of rule 3 for an error passive
                                -- transmitter is resolved during its passive error flag
                                v.ErrAck := '1';
                                if isPassive(r) then
                                    startErrorFlag(v, 0, 0, Cfg_ListenOnly);
                                    v.AckErrPass := '1';
                                else
                                    startErrorFlag(v, 8, 0, Cfg_ListenOnly);
                                end if;
                            else
                                v.Fsm := AckDel_s;
                            end if;
                        else
                            -- Successful reception (rule 8): ACK sent and seen
                            if r.Monitor = '1' and Cfg_ListenOnly = '0' then
                                if r.Rec > 127 then
                                    v.Rec := to_unsigned(119, v.Rec'length);
                                elsif r.Rec > 0 then
                                    v.Rec := r.Rec - 1;
                                end if;
                            end if;
                            v.Fsm := AckDel_s;
                        end if;

                    when AckDel_s =>
                        if Bit_v = Dominant_c then
                            v.ErrForm := '1';
                            if r.IsTx = '1' then
                                startErrorFlag(v, 8, 0, Cfg_ListenOnly);
                            else
                                startErrorFlag(v, 0, 1, Cfg_ListenOnly);
                            end if;
                        elsif r.CrcErr = '1' and r.IsTx = '0' then
                            -- CRC error: error flag after the ACK delimiter (section 7.2)
                            v.ErrCrc := '1';
                            startErrorFlag(v, 0, 1, Cfg_ListenOnly);
                        else
                            v.Fsm    := Eof_s;
                            v.BitCnt := (others => '0');
                        end if;

                    when Eof_s =>
                        if Bit_v = Dominant_c and not (r.BitCnt = 6 and r.IsTx = '0') then
                            -- Form error (a receiver ignores the last bit, section 5)
                            v.ErrForm := '1';
                            if r.IsTx = '1' then
                                startErrorFlag(v, 8, 0, Cfg_ListenOnly);
                            else
                                startErrorFlag(v, 0, 1, Cfg_ListenOnly);
                            end if;
                        else
                            -- Receiver: valid after the last but one bit of EOF
                            if r.BitCnt = 5 and (r.IsTx = '0' or Cfg_Loopback = '1') then
                                v.RxValid := '1';
                            end if;
                            if r.BitCnt = 6 then
                                -- Transmitter: valid after the last bit of EOF (rule 7)
                                if r.IsTx = '1' then
                                    v.TxDone     := '1';
                                    v.TxPending  := '0';
                                    v.TxAbortReq := '0';
                                    if r.Tec > 0 and Cfg_ListenOnly = '0' then
                                        v.Tec := r.Tec - 1;
                                    end if;
                                end if;
                                v.Fsm    := Intermission_s;
                                v.BitCnt := (others => '0');
                            else
                                v.BitCnt := r.BitCnt + 1;
                            end if;
                        end if;

                    -- *** Interframe space ***
                    when Intermission_s =>
                        if Bit_v = Dominant_c then
                            if r.BitCnt = 2 then
                                -- Dominant third bit: start of frame; a pending frame continues with its
                                -- identifier without SOF (section 3.2.5)
                                startFrame(v);
                                v.IsTx := '1' when MayTx_v and not (r.IsTx = '1' and isPassive(r)) else '0';
                            else
                                -- Overload condition 2
                                startOverloadFlag(v, Cfg_ListenOnly);
                            end if;
                        elsif r.BitCnt = 2 then
                            v.BitCnt := (others => '0');
                            if r.IsTx = '1' and isPassive(r) then
                                v.Fsm := Suspend_s;
                            else
                                v.Fsm := Idle_s;
                            end if;
                            v.IsTx := '0';
                        else
                            v.BitCnt := r.BitCnt + 1;
                        end if;

                    when Suspend_s =>
                        if Bit_v = Dominant_c then
                            -- Another node starts a frame: become its receiver
                            startFrame(v);
                        elsif r.BitCnt = 7 then
                            v.Fsm    := Idle_s;
                            v.BitCnt := (others => '0');
                        else
                            v.BitCnt := r.BitCnt + 1;
                        end if;

                    -- *** Error and overload frames ***
                    when ErrFlag_s =>
                        if r.FlagActive = '1' then
                            if Bit_v = Recessive_c then
                                -- Bit error during an active error flag (rules 4 and 5)
                                v.ErrBit := '1';
                                if r.IsTx = '1' then
                                    startErrorFlag(v, 8, 0, Cfg_ListenOnly);
                                else
                                    startErrorFlag(v, 0, 8, Cfg_ListenOnly);
                                end if;
                            elsif r.BitCnt = 5 then
                                v.Fsm        := DelimWait_s;
                                v.DomCnt     := (others => '0');
                                v.FirstAfter := '1';
                            else
                                v.BitCnt := r.BitCnt + 1;
                            end if;
                        else
                            -- Passive error flag: complete after 6 consecutive equal bits
                            if r.EqCnt /= 0 and Bit_v = r.EqVal then
                                v.EqCnt := r.EqCnt + 1;
                            else
                                v.EqCnt := to_unsigned(1, v.EqCnt'length);
                                v.EqVal := Bit_v;
                            end if;
                            if Bit_v = Dominant_c and r.AckErrPass = '1' then
                                -- Exception 1 of rule 3 does not apply: dominant bit during the flag
                                incCounters(v, 8, 0, Cfg_ListenOnly);
                                v.AckErrPass := '0';
                                if v.Tec >= 256 then
                                    v.Fsm        := BusOff_s;
                                    v.BusOff     := '1';
                                    v.IsTx       := '0';
                                    v.RecessCnt  := (others => '0');
                                    v.SeqCnt     := (others => '0');
                                    v.RecoverReq := '0';
                                end if;
                            end if;
                            if v.Fsm = ErrFlag_s and v.EqCnt = 6 then
                                v.Fsm        := DelimWait_s;
                                v.DomCnt     := (others => '0');
                                v.FirstAfter := '1';
                                v.AckErrPass := '0';
                            end if;
                        end if;

                    when OvlFlag_s =>
                        if Bit_v = Recessive_c and r.FlagActive = '1' then
                            -- Bit error during an overload flag (rules 4 and 5)
                            v.ErrBit := '1';
                            if r.IsTx = '1' then
                                startErrorFlag(v, 8, 0, Cfg_ListenOnly);
                            else
                                startErrorFlag(v, 0, 8, Cfg_ListenOnly);
                            end if;
                        elsif r.BitCnt = 5 then
                            v.Fsm        := DelimWait_s;
                            v.DomCnt     := (others => '0');
                            v.FirstAfter := '1';
                        else
                            v.BitCnt := r.BitCnt + 1;
                        end if;

                    when DelimWait_s =>
                        -- Wait for the first recessive bit of the delimiter
                        v.FirstAfter := '0';
                        if Bit_v = Dominant_c then
                            -- Rule 2: dominant first bit after an error flag at a receiver
                            if r.FirstAfter = '1' and r.FlagIsError = '1' and r.IsTx = '0' then
                                incCounters(v, 0, 8, Cfg_ListenOnly);
                            end if;
                            -- Rule 6: every 8 further consecutive dominant bits
                            if r.DomCnt = 7 then
                                v.DomCnt := (others => '0');
                                if r.IsTx = '1' then
                                    incCounters(v, 8, 0, Cfg_ListenOnly);
                                else
                                    incCounters(v, 0, 8, Cfg_ListenOnly);
                                end if;
                            else
                                v.DomCnt := r.DomCnt + 1;
                            end if;
                            if v.Tec >= 256 then
                                v.Fsm        := BusOff_s;
                                v.BusOff     := '1';
                                v.IsTx       := '0';
                                v.RecessCnt  := (others => '0');
                                v.SeqCnt     := (others => '0');
                                v.RecoverReq := '0';
                            end if;
                        else
                            v.Fsm    := Delim_s;
                            v.BitCnt := to_unsigned(1, v.BitCnt'length);
                        end if;

                    when Delim_s =>
                        if Bit_v = Dominant_c then
                            if r.BitCnt = 7 then
                                -- Overload condition 3 (no counter change)
                                startOverloadFlag(v, Cfg_ListenOnly);
                            else
                                v.ErrForm := '1';
                                if r.IsTx = '1' then
                                    startErrorFlag(v, 8, 0, Cfg_ListenOnly);
                                else
                                    startErrorFlag(v, 0, 1, Cfg_ListenOnly);
                                end if;
                            end if;
                        elsif r.BitCnt = 7 then
                            v.Fsm    := Intermission_s;
                            v.BitCnt := (others => '0');
                        else
                            v.BitCnt := r.BitCnt + 1;
                        end if;

                    -- *** Bus off: recovery after 128 x 11 recessive bits (rule 12) ***
                    when BusOff_s =>
                        if AutoRecover_g or r.RecoverReq = '1' then
                            if Bit_v = Recessive_c then
                                if r.RecessCnt = 10 then
                                    v.RecessCnt := (others => '0');
                                    if r.SeqCnt = 127 then
                                        v.SeqCnt     := (others => '0');
                                        v.Tec        := (others => '0');
                                        v.Rec        := (others => '0');
                                        v.BusOff     := '0';
                                        v.RecoverReq := '0';
                                        v.Fsm        := Idle_s;
                                    else
                                        v.SeqCnt := r.SeqCnt + 1;
                                    end if;
                                else
                                    v.RecessCnt := r.RecessCnt + 1;
                                end if;
                            else
                                v.RecessCnt := (others => '0');
                            end if;
                        end if;

                    -- coverage off
                    when others => -- unreachable
                        v.Fsm := Integrating_s;
                    -- coverage on

                end case;

            end if;

            -- *** Bit to send next ***
            if isFrameField(v.Fsm) then
                if v.IsTx = '1' then
                    v.Monitor := '1';
                    if v.StuffNext = '1' then
                        v.TxBit := not v.StuffLast;
                    else

                        case v.Fsm is
                            when Id_s =>
                                v.TxBit := v.TxId(28 - to_integer(v.BitCnt));
                            when SrrRtr_s =>
                                v.TxBit := v.TxIde or v.TxRtr; -- SRR (recessive) or RTR
                            when Ide_s =>
                                v.TxBit := v.TxIde;
                            when IdExt_s =>
                                v.TxBit := v.TxId(17 - to_integer(v.BitCnt));
                            when RtrExt_s =>
                                v.TxBit := v.TxRtr;
                            when R1_s | R0_s =>
                                v.TxBit := Dominant_c;
                            when Dlc_s =>
                                v.TxBit := v.TxDlc(3 - to_integer(v.BitCnt));
                            when Data_s =>
                                v.TxBit := v.TxData(63 - to_integer(v.BitCnt));
                            when Crc_s =>
                                v.TxBit := v.Crc(14 - to_integer(v.BitCnt));
                            when AckSlot_s =>
                                v.TxBit := not Cfg_Loopback; -- own acknowledge in loopback mode
                            when others =>
                                v.TxBit := Recessive_c; -- delimiters, EOF
                        end case;

                    end if;
                    -- Arbitration field of the next bit
                    if v.Fsm = Id_s or v.Fsm = SrrRtr_s or v.Fsm = IdExt_s or v.Fsm = RtrExt_s or
                       (v.Fsm = Ide_s and v.TxIde = '1') then
                        v.InArb := '1';
                    else
                        v.InArb := '0';
                    end if;
                else
                    -- Receiver: recessive, except the acknowledge of a frame with a matching CRC
                    v.InArb := '0';
                    if v.Fsm = AckSlot_s and v.CrcErr = '0' and Cfg_ListenOnly = '0' then
                        v.TxBit   := Dominant_c;
                        v.Monitor := '1';
                    else
                        v.TxBit   := Recessive_c;
                        v.Monitor := '0';
                    end if;
                end if;
            elsif v.Fsm = Idle_s then
                -- Start of frame of a pending frame (the bus is idle at this sample)
                v.InArb := '0';
                if MayTx_v and v.TxPending = '1' and v.TxAbortReq = '0' then
                    v.IsTx    := '1';
                    v.TxBit   := Dominant_c;
                    v.Monitor := '1';
                else
                    v.IsTx    := '0';
                    v.TxBit   := Recessive_c;
                    v.Monitor := '0';
                end if;
            elsif v.Fsm /= ErrFlag_s and v.Fsm /= OvlFlag_s then
                -- Delimiters, interframe space, integration, bus off: recessive
                v.InArb   := '0';
                v.TxBit   := Recessive_c;
                v.Monitor := '0';
            end if;
        end if;

        -- *** Transmit point: start of SYNC_SEG ***
        if BitStart_v then
            v.CanTxInt := v.TxBit;
        end if;

        -- *** Disabled controller: integrate again when enabled (fault confinement state is kept) ***
        if Cfg_Enable = '0' then
            v.PrescCnt   := (others => '0');
            v.TqCnt      := (others => '0');
            v.Lengthen   := (others => '0');
            v.Shorten    := (others => '0');
            v.SyncDone   := '0';
            v.LastSample := Recessive_c;
            v.CanTxInt   := Recessive_c;
            v.TxBit      := Recessive_c;
            v.Monitor    := '0';
            v.InArb      := '0';
            v.StuffNext  := '0';
            v.IsTx       := '0';
            v.RecessCnt  := (others => '0');
            if r.BusOff = '0' then
                v.Fsm := Integrating_s;
            end if;
        end if;

        -- *** Aborted frame that is not on the bus (any more): dropped ***
        if v.TxAbortReq = '1' and v.IsTx = '0' then
            v.TxPending  := '0';
            v.TxAbortReq := '0';
            v.TxAborted  := '1';
        end if;

        -- *** Bus pin (recessive when not allowed to drive) ***
        if Cfg_Loopback = '1' or Cfg_ListenOnly = '1' or v.BusOff = '1' or Cfg_Enable = '0' then
            v.CanTx := Recessive_c;
        else
            v.CanTx := v.CanTxInt;
        end if;

        -- *** Outputs ***
        Tx_Ready   <= not r.TxPending;
        Tx_Done    <= r.TxDone;
        Tx_Aborted <= r.TxAborted;
        Tx_ArbLost <= r.TxArbLost;
        Rx_Valid   <= r.RxValid;
        Rx_Id      <= r.RxIdBase & r.RxIdExt;
        Rx_Ide     <= r.RxIde;
        Rx_Rtr     <= r.RxRtr;
        Rx_Dlc     <= r.RxDlc;
        Rx_Data    <= r.RxData;
        Stat_Tec   <= std_logic_vector(r.Tec);
        Stat_Rec   <= std_logic_vector(r.Rec);
        if r.BusOff = '1' then
            Stat_State <= "11";
        elsif isPassive(r) then
            Stat_State <= "01";
        else
            Stat_State <= "00";
        end if;
        Stat_BusIdle <= '1' when r.Fsm = Idle_s else '0';
        Err_Bit      <= r.ErrBit;
        Err_Stuff    <= r.ErrStuff;
        Err_Crc      <= r.ErrCrc;
        Err_Form     <= r.ErrForm;
        Err_Ack      <= r.ErrAck;
        Can_Tx       <= r.CanTx;

        -- *** Assign to signal ***
        r_next <= v;
    end process;

    -----------------------------------------------------------------------------------------------
    -- Sequential Process
    -----------------------------------------------------------------------------------------------
    p_seq : process (Clk) is
    begin
        if rising_edge(Clk) then
            r <= r_next;
            if Rst = '1' then
                r.PrescCnt   <= (others => '0');
                r.TqCnt      <= (others => '0');
                r.Lengthen   <= (others => '0');
                r.Shorten    <= (others => '0');
                r.SyncDone   <= '0';
                r.RxPrev     <= Recessive_c;
                r.LastSample <= Recessive_c;
                r.CanTxInt   <= Recessive_c;
                r.CanTx      <= Recessive_c;
                r.Fsm        <= Integrating_s;
                r.BitCnt     <= (others => '0');
                r.TxBit      <= Recessive_c;
                r.Monitor    <= '0';
                r.InArb      <= '0';
                r.StuffNext  <= '0';
                r.IsTx       <= '0';
                r.TxPending  <= '0';
                r.TxAbortReq <= '0';
                r.AckErrPass <= '0';
                r.Tec        <= (others => '0');
                r.Rec        <= (others => '0');
                r.BusOff     <= '0';
                r.RecessCnt  <= (others => '0');
                r.SeqCnt     <= (others => '0');
                r.RecoverReq <= '0';
                r.RxValid    <= '0';
                r.TxDone     <= '0';
                r.TxAborted  <= '0';
                r.TxArbLost  <= '0';
                r.ErrBit     <= '0';
                r.ErrStuff   <= '0';
                r.ErrCrc     <= '0';
                r.ErrForm    <= '0';
                r.ErrAck     <= '0';
            end if;
        end if;
    end process;

    -----------------------------------------------------------------------------------------------
    -- Component Instantiations
    -----------------------------------------------------------------------------------------------
    -- Synchroniser of the bus input (reset level recessive)
    i_sync : entity work.olo_intf_sync
        generic map (
            Width_g      => 1,
            RstLevel_g   => Recessive_c,
            SyncStages_g => SyncStages_g,
            SyncTmr_g    => SyncTmr_g
        )
        port map (
            Clk          => Clk,
            Rst          => Rst,
            DataAsync(0) => Can_Rx,
            DataSync(0)  => RxSync
        );

end architecture;
