---------------------------------------------------------------------------------------------------
-- Copyright (c) 2026 by Julian Schneider
-- Authors: Julian Schneider
---------------------------------------------------------------------------------------------------

---------------------------------------------------------------------------------------------------
-- Description
---------------------------------------------------------------------------------------------------
-- Random back-to-back commands for olo_axi_master_full against a memory model: random sizes and
-- start offsets, FIXED and INCR commands, both latency modes, error windows and random stalls on
-- all channels. The written memory is compared with a reference model, every read word is checked,
-- and the throughput of back-to-back commands is measured.

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
    use olo.olo_base_pkg_logic.all;
    use olo.olo_axi_pkg_protocol.all;

---------------------------------------------------------------------------------------------------
-- Entity
---------------------------------------------------------------------------------------------------
-- vunit: run_all_in_same_sim
entity olo_axi_master_full_random_tb is
    generic (
        AxiDataWidth_g  : natural range 8 to 1024 := 32;
        UserDataWidth_g : natural                 := 32;
        AxiMaxBeats_g   : natural range 1 to 256  := 16;
        StallPercent_g  : natural range 0 to 90   := 0;
        Seed_g          : positive                := 1;
        TpWrPermille_g  : natural range 0 to 1000 := 850;
        TpRdPermille_g  : natural range 0 to 1000 := 850;
        runner_cfg      : string
    );
end entity;

architecture sim of olo_axi_master_full_random_tb is

    -----------------------------------------------------------------------------------------------
    -- Constants
    -----------------------------------------------------------------------------------------------
    constant AxiAddrWidth_c  : natural := 32;
    constant SizeBits_c      : natural := 16;
    constant DataFifoDepth_c : natural := maximum(64, 2*AxiMaxBeats_g);
    constant MaxOpen_c       : natural := 3;
    constant AxiBytes_c      : natural := AxiDataWidth_g/8;
    constant UserBytes_c     : natural := UserDataWidth_g/8;

    -- Memory of the model: two halves, so that one is read while the other is written
    constant MemBytes_c : natural := 16384;
    constant Half_c     : natural := MemBytes_c/2;

    -- Error window of each half: every burst (write) or beat (read) that touches it responds with SLVERR
    constant ErrOffset_c : natural := 3840;
    constant ErrBytes_c  : natural := 2*AxiBytes_c;

    -- Commands per phase and direction, largest command
    constant NumCmd_c  : natural := 40;
    constant MaxCmd_c  : natural := 64;
    constant MaxSize_c : natural := minimum(3*AxiMaxBeats_g*AxiBytes_c+AxiBytes_c, Half_c/4);

    -- Throughput: commands of TpWords_c AXI words, measured over TpCmds_c commands
    constant TpWords_c   : natural := 16;
    constant TpCmds_c    : natural := 20;
    constant RdLatency_c : natural := 8;

    -- FIXED bursts have at most 16 beats (AXI4)
    constant FixedMaxBeats_c : natural := minimum(AxiMaxBeats_g, 16);

    -----------------------------------------------------------------------------------------------
    -- TB Definitions
    -----------------------------------------------------------------------------------------------
    constant Clk_Period_c : time := 10 ns;

    type Cmd_t is record
        Addr   : natural;
        Size   : natural;
        Fixed  : boolean;
        LowLat : boolean;
        Error  : boolean;
        Index  : natural;
    end record;

    type CmdArray_t is array (0 to MaxCmd_c-1) of Cmd_t;

    -- Byte memory
    type ByteMem_t is protected

        procedure setByte (addr : natural; value : natural);
        impure function getByte (addr : natural) return natural;
    end protected;

    type ByteMem_t is protected body
        type Mem_t is array (0 to MemBytes_c-1) of natural range 0 to 255;

        variable Mem_v : Mem_t := (others => 0);

        procedure setByte (addr : natural; value : natural) is
        begin
            Mem_v(addr) := value;
        end procedure;

        impure function getByte (addr : natural) return natural is
        begin
            return Mem_v(addr);
        end function;

    end protected body;

    -- Command list of a phase
    type CmdList_t is protected

        procedure clear;

        procedure push (cmd : Cmd_t);
        impure function count return natural;
        impure function get (idx : natural) return Cmd_t;
    end protected;

    type CmdList_t is protected body
        variable List_v  : CmdArray_t;
        variable Count_v : natural := 0;

        procedure clear is
        begin
            Count_v := 0;
        end procedure;

        procedure push (cmd : Cmd_t) is
        begin
            List_v(Count_v) := cmd;
            Count_v         := Count_v + 1;
        end procedure;

        impure function count return natural is
        begin
            return Count_v;
        end function;

        impure function get (idx : natural) return Cmd_t is
        begin
            return List_v(idx);
        end function;

    end protected body;

    shared variable SlaveMem_v : ByteMem_t;
    shared variable RefMem_v   : ByteMem_t;
    shared variable WrList_v   : CmdList_t;
    shared variable RdList_v   : CmdList_t;

    -- Byte value without a period: depends on every bit of its index
    function hashByte (idx : natural) return natural is
        variable X_v : unsigned(31 downto 0);
    begin
        X_v := to_unsigned(idx, 32);
        X_v := resize(X_v * to_unsigned(16#1E3779B1#, 32), 32);
        X_v := X_v xor shift_right(X_v, 15);
        X_v := resize(X_v * to_unsigned(16#05EBCA6B#, 32), 32);
        X_v := X_v xor shift_right(X_v, 13);
        return to_integer(X_v(7 downto 0));
    end function;

    -- Data byte i of command idx, and the initial content of the memory
    function dataByte (idx : natural; i : natural) return natural is
    begin
        return hashByte(idx*65536 + i);
    end function;

    function initByte (addr : natural) return natural is
    begin
        return hashByte(2**30 + addr);
    end function;

    -- AXI word of an address
    function wordOf (addr : natural) return natural is
    begin
        return (addr/AxiBytes_c)*AxiBytes_c;
    end function;

    -- Memory address of byte i of a command (a FIXED command accesses the AXI word of its address)
    function byteAddr (cmd : Cmd_t; i : natural) return natural is
    begin
        if cmd.Fixed then
            return wordOf(cmd.Addr) + (i mod AxiBytes_c);
        end if;
        return cmd.Addr + i;
    end function;

    -- A word in the error window of its half
    function inErrWindow (word : natural) return boolean is
        constant Offs_c : natural := word mod Half_c;
    begin
        return (Offs_c+AxiBytes_c > ErrOffset_c) and (Offs_c < ErrOffset_c+ErrBytes_c);
    end function;

    -- Expected failure of a command: any AXI word of the command in the error window
    function cmdError (cmd : Cmd_t) return boolean is
        variable Word_v : natural;
    begin
        if cmd.Fixed then
            return inErrWindow(wordOf(cmd.Addr));
        end if;
        Word_v := wordOf(cmd.Addr);

        while Word_v <= wordOf(cmd.Addr+cmd.Size-1) loop
            if inErrWindow(Word_v) then
                return true;
            end if;
            Word_v := Word_v + AxiBytes_c;
        end loop;

        return false;
    end function;

    -----------------------------------------------------------------------------------------------
    -- Interface Signals
    -----------------------------------------------------------------------------------------------
    signal Clk          : std_logic                                      := '0';
    signal Rst          : std_logic                                      := '1';
    signal CmdWr_Addr   : std_logic_vector(AxiAddrWidth_c - 1 downto 0)  := (others => '0');
    signal CmdWr_Size   : std_logic_vector(SizeBits_c - 1 downto 0)      := (others => '0');
    signal CmdWr_LowLat : std_logic                                      := '0';
    signal CmdWr_Fixed  : std_logic                                      := '0';
    signal CmdWr_Valid  : std_logic                                      := '0';
    signal CmdWr_Ready  : std_logic;
    signal CmdRd_Addr   : std_logic_vector(AxiAddrWidth_c - 1 downto 0)  := (others => '0');
    signal CmdRd_Size   : std_logic_vector(SizeBits_c - 1 downto 0)      := (others => '0');
    signal CmdRd_LowLat : std_logic                                      := '0';
    signal CmdRd_Fixed  : std_logic                                      := '0';
    signal CmdRd_Valid  : std_logic                                      := '0';
    signal CmdRd_Ready  : std_logic;
    signal Wr_Data      : std_logic_vector(UserDataWidth_g - 1 downto 0) := (others => '0');
    signal Wr_Valid     : std_logic                                      := '0';
    signal Wr_Ready     : std_logic;
    signal Rd_Data      : std_logic_vector(UserDataWidth_g - 1 downto 0);
    signal Rd_Last      : std_logic;
    signal Rd_Valid     : std_logic;
    signal Rd_Ready     : std_logic                                      := '0';
    signal Wr_Done      : std_logic;
    signal Wr_Error     : std_logic;
    signal Wr_ErrorResp : std_logic_vector(1 downto 0);
    signal Rd_Done      : std_logic;
    signal Rd_Error     : std_logic;
    signal Rd_ErrorResp : std_logic_vector(1 downto 0);

    signal AwAddr  : std_logic_vector(AxiAddrWidth_c - 1 downto 0);
    signal AwLen   : std_logic_vector(7 downto 0);
    signal AwSize  : std_logic_vector(2 downto 0);
    signal AwBurst : std_logic_vector(1 downto 0);
    signal AwValid : std_logic;
    signal AwReady : std_logic                                     := '0';
    signal WData   : std_logic_vector(AxiDataWidth_g - 1 downto 0);
    signal WStrb   : std_logic_vector(AxiBytes_c - 1 downto 0);
    signal WLast   : std_logic;
    signal WValid  : std_logic;
    signal WReady  : std_logic                                     := '0';
    signal BResp   : std_logic_vector(1 downto 0)                  := (others => '0');
    signal BValid  : std_logic                                     := '0';
    signal BReady  : std_logic;
    signal ArAddr  : std_logic_vector(AxiAddrWidth_c - 1 downto 0);
    signal ArLen   : std_logic_vector(7 downto 0);
    signal ArSize  : std_logic_vector(2 downto 0);
    signal ArBurst : std_logic_vector(1 downto 0);
    signal ArValid : std_logic;
    signal ArReady : std_logic                                     := '0';
    signal RData   : std_logic_vector(AxiDataWidth_g - 1 downto 0) := (others => '0');
    signal RResp   : std_logic_vector(1 downto 0)                  := (others => '0');
    signal RLast   : std_logic                                     := '0';
    signal RValid  : std_logic                                     := '0';
    signal RReady  : std_logic;

    -- Test control
    signal Phase       : natural := 0;
    signal StallEna    : boolean := false;
    signal WrRespCnt   : natural := 0;
    signal WrRespPhase : natural := 0;
    signal RdRespCnt   : natural := 0;
    signal RdRespPhase : natural := 0;
    signal RdDataCnt   : natural := 0;
    signal RdDataPhase : natural := 0;
    signal WrFirst     : natural := 0;
    signal WrLast      : natural := 0;
    signal RdFirst     : natural := 0;
    signal RdLast      : natural := 0;
    signal Cycle       : natural := 0;

    -- Random gap of 1 to 4 clock cycles with the stall probability
    procedure randomGap (
        signal clk : in std_logic;
        stall      : boolean;
        seed1,
        seed2      : inout positive) is
        variable Rand_v : real;
    begin
        if stall then
            uniform(seed1, seed2, Rand_v);
            if Rand_v*100.0 < real(StallPercent_g) then
                uniform(seed1, seed2, Rand_v);

                for i in 0 to integer(floor(Rand_v*3.99)) loop
                    wait until rising_edge(clk);
                end loop;

            end if;
        end if;
    end procedure;

begin

    -----------------------------------------------------------------------------------------------
    -- TB Control
    -----------------------------------------------------------------------------------------------
    test_runner_watchdog(runner, 50 ms);

    p_control : process is
        variable Seed1_v, Seed2_v : positive;
        variable Cmd_v            : Cmd_t;
        variable Index_v          : natural := 0;

        -- Random command in a half (base: first byte of the half)
        procedure randomCmd (base : natural; cmd : out Cmd_t) is
            variable C_v : Cmd_t;
            variable R_v : real;
        begin
            uniform(Seed1_v, Seed2_v, R_v);
            C_v.Fixed  := R_v < 0.15;
            uniform(Seed1_v, Seed2_v, R_v);
            C_v.LowLat := R_v < 0.3;
            -- Sizes: 1, one AXI word, one more byte, or random up to MaxSize_c
            uniform(Seed1_v, Seed2_v, R_v);
            if R_v < 0.1 then
                C_v.Size := 1;
            elsif R_v < 0.2 then
                C_v.Size := AxiBytes_c;
            elsif R_v < 0.3 then
                C_v.Size := AxiBytes_c+1;
            else
                uniform(Seed1_v, Seed2_v, R_v);
                C_v.Size := 1 + integer(floor(R_v*real(MaxSize_c-1)));
            end if;
            uniform(Seed1_v, Seed2_v, R_v);
            C_v.Addr  := base + integer(floor(R_v*real(Half_c-C_v.Size-AxiBytes_c)));
            C_v.Error := cmdError(C_v);
            C_v.Index := Index_v;
            Index_v   := Index_v + 1;
            cmd       := C_v;
        end procedure;

        -- Apply a write command to the reference memory
        procedure refWrite (cmd : Cmd_t) is
        begin

            for i in 0 to cmd.Size-1 loop
                RefMem_v.setByte(byteAddr(cmd, i), dataByte(cmd.Index, i));
            end loop;

        end procedure;

        -- Start a phase and wait for all its responses and read data
        procedure runPhase is
            variable Next_v : natural;
        begin
            Next_v := Phase + 1;
            Phase  <= Next_v;
            wait until rising_edge(Clk) and
                       WrRespPhase = Next_v and WrRespCnt = WrList_v.count and
                       RdRespPhase = Next_v and RdRespCnt = RdList_v.count and
                       RdDataPhase = Next_v and RdDataCnt = RdList_v.count;
        end procedure;

        -- Compare the memory of the model with the reference
        procedure compareMem (first : natural; bytes : natural) is
        begin

            for a in first to first+bytes-1 loop
                check_equal(SlaveMem_v.getByte(a), RefMem_v.getByte(a), "Memory byte " & integer'image(a));
            end loop;

        end procedure;

        variable Beats_v    : natural;
        variable Expected_v : real;
    begin
        test_runner_setup(runner, runner_cfg);
        Seed1_v := Seed_g;
        Seed2_v := 7;

        while test_suite loop

            -- Initial memory content and reset
            for a in 0 to MemBytes_c-1 loop
                SlaveMem_v.setByte(a, initByte(a));
                RefMem_v.setByte(a, initByte(a));
            end loop;

            wait until rising_edge(Clk);
            Rst <= '1';
            wait for 1 us;
            wait until rising_edge(Clk);
            Rst <= '0';
            wait until rising_edge(Clk);

            -- *** Random commands ***
            -- Phase 1 writes half 0. Phase 2 writes half 1 and reads half 0, phase 3 writes half 0 and reads
            -- half 1, phase 4 reads half 0.
            if run("RandomCommands") then
                StallEna <= StallPercent_g > 0;

                for p in 1 to 4 loop
                    WrList_v.clear;
                    RdList_v.clear;
                    if p <= 3 then

                        for i in 0 to NumCmd_c-1 loop
                            randomCmd(((p+1) mod 2)*Half_c, Cmd_v);
                            WrList_v.push(Cmd_v);
                            refWrite(Cmd_v);
                        end loop;

                    end if;
                    if p >= 2 then

                        for i in 0 to NumCmd_c-1 loop
                            randomCmd((p mod 2)*Half_c, Cmd_v);
                            RdList_v.push(Cmd_v);
                        end loop;

                    end if;
                    runPhase;
                    compareMem(0, MemBytes_c);
                end loop;

            end if;

            -- *** Throughput of back-to-back commands ***
            -- Aligned INCR commands of TpWords_c AXI words, without stalls. Expected rate in user words per
            -- clock cycle: the width ratio times the rate of olo_axi_master_simple (one burst per 4 cycles at
            -- most), at most 1; the test requires TpWrPermille_g and TpRdPermille_g of it (per mille). Where the
            -- chaining of the commands sets the rate, the configuration sets the bounds tight enough to detect one
            -- lost cycle per command.
            if run("Throughput") then
                StallEna <= false;
                WrList_v.clear;
                RdList_v.clear;

                for i in 0 to TpCmds_c-1 loop
                    Cmd_v       := (Addr => i*TpWords_c*AxiBytes_c mod Half_c,
                                    Size => TpWords_c*AxiBytes_c,
                                    Fixed => false,
                                    LowLat => false,
                                    Error => false,
                                    Index => Index_v);
                    Index_v     := Index_v + 1;
                    Cmd_v.Error := cmdError(Cmd_v);
                    WrList_v.push(Cmd_v);
                    refWrite(Cmd_v);
                end loop;

                runPhase;
                -- Reads of the same commands
                WrList_v.clear;

                for i in 0 to TpCmds_c-1 loop
                    Cmd_v       := (Addr => i*TpWords_c*AxiBytes_c mod Half_c,
                                    Size => TpWords_c*AxiBytes_c,
                                    Fixed => false,
                                    LowLat => false,
                                    Error => false,
                                    Index => 0);
                    Cmd_v.Error := cmdError(Cmd_v);
                    RdList_v.push(Cmd_v);
                end loop;

                runPhase;
                Beats_v    := TpCmds_c*((TpWords_c*AxiBytes_c+UserBytes_c-1)/UserBytes_c);
                Expected_v := minimum(1.0, real(AxiBytes_c/UserBytes_c)*minimum(1.0, real(minimum(AxiMaxBeats_g, TpWords_c))/4.0));
                info("Throughput write " & integer'image(Beats_v) & " beats in " & integer'image(WrLast-WrFirst+1) &
                     " cycles, read " & integer'image(Beats_v) & " beats in " & integer'image(RdLast-RdFirst+1) & " cycles");
                check(real(Beats_v)*1000.0 >= real(TpWrPermille_g)*Expected_v*real(WrLast-WrFirst+1),
                      "Write throughput below " & integer'image(TpWrPermille_g) & " per mille of the expected rate");
                check(real(Beats_v)*1000.0 >= real(TpRdPermille_g)*Expected_v*real(RdLast-RdFirst+1),
                      "Read throughput below " & integer'image(TpRdPermille_g) & " per mille of the expected rate");
            end if;

            wait for 1 us;

        end loop;

        -- TB done
        test_runner_cleanup(runner);
    end process;

    -----------------------------------------------------------------------------------------------
    -- Write commands and data
    -----------------------------------------------------------------------------------------------
    p_wr_cmd : process is
        variable Seed1_v, Seed2_v : positive;
        variable Cmd_v            : Cmd_t;
    begin
        Seed1_v := Seed_g + 11;
        Seed2_v := 13;

        loop
            wait on Phase;

            for i in 0 to WrList_v.count-1 loop
                Cmd_v        := WrList_v.get(i);
                randomGap(Clk, StallEna, Seed1_v, Seed2_v);
                CmdWr_Addr   <= toUslv(Cmd_v.Addr, AxiAddrWidth_c);
                CmdWr_Size   <= toUslv(Cmd_v.Size, SizeBits_c);
                CmdWr_Fixed  <= choose(Cmd_v.Fixed, '1', '0');
                CmdWr_LowLat <= choose(Cmd_v.LowLat, '1', '0');
                CmdWr_Valid  <= '1';
                wait until rising_edge(Clk) and CmdWr_Ready = '1';
                CmdWr_Valid  <= '0';
            end loop;

        end loop;

    end process;

    p_wr_data : process is
        variable Seed1_v, Seed2_v : positive;
        variable Cmd_v            : Cmd_t;
        variable Words_v          : natural;
    begin
        Seed1_v := Seed_g + 17;
        Seed2_v := 19;

        loop
            wait on Phase;

            for i in 0 to WrList_v.count-1 loop
                Cmd_v   := WrList_v.get(i);
                Words_v := (Cmd_v.Size+UserBytes_c-1)/UserBytes_c;

                for w in 0 to Words_v-1 loop
                    randomGap(Clk, StallEna, Seed1_v, Seed2_v);

                    -- The bytes beyond the size are random as well and must not be written
                    for b in 0 to UserBytes_c-1 loop
                        Wr_Data(b*8+7 downto b*8) <= toUslv(dataByte(Cmd_v.Index, w*UserBytes_c+b), 8);
                    end loop;

                    Wr_Valid <= '1';
                    wait until rising_edge(Clk) and Wr_Ready = '1';
                    if i = 0 and w = 0 then
                        WrFirst <= Cycle;
                    end if;
                    WrLast   <= Cycle;
                    Wr_Valid <= '0';
                end loop;

            end loop;

        end loop;

    end process;

    -----------------------------------------------------------------------------------------------
    -- Read commands and data check
    -----------------------------------------------------------------------------------------------
    p_rd_cmd : process is
        variable Seed1_v, Seed2_v : positive;
        variable Cmd_v            : Cmd_t;
    begin
        Seed1_v := Seed_g + 23;
        Seed2_v := 29;

        loop
            wait on Phase;

            for i in 0 to RdList_v.count-1 loop
                Cmd_v        := RdList_v.get(i);
                randomGap(Clk, StallEna, Seed1_v, Seed2_v);
                CmdRd_Addr   <= toUslv(Cmd_v.Addr, AxiAddrWidth_c);
                CmdRd_Size   <= toUslv(Cmd_v.Size, SizeBits_c);
                CmdRd_Fixed  <= choose(Cmd_v.Fixed, '1', '0');
                CmdRd_LowLat <= choose(Cmd_v.LowLat, '1', '0');
                CmdRd_Valid  <= '1';
                wait until rising_edge(Clk) and CmdRd_Ready = '1';
                CmdRd_Valid  <= '0';
            end loop;

        end loop;

    end process;

    p_rd_data : process is
        variable Seed1_v, Seed2_v : positive;
        variable Rand_v           : real;
        variable Cmd_v            : Cmd_t;
        variable Words_v          : natural;
        variable Byte_v           : natural;
    begin
        Seed1_v := Seed_g + 31;
        Seed2_v := 37;

        loop
            wait on Phase;
            RdDataCnt   <= 0;
            RdDataPhase <= Phase;

            for i in 0 to RdList_v.count-1 loop
                Cmd_v   := RdList_v.get(i);
                Words_v := (Cmd_v.Size+UserBytes_c-1)/UserBytes_c;

                for w in 0 to Words_v-1 loop

                    -- Wait for the word with a randomly stalled Rd_Ready
                    loop
                        Rd_Ready <= '1';
                        if StallEna then
                            uniform(Seed1_v, Seed2_v, Rand_v);
                            if Rand_v*100.0 < real(StallPercent_g) then
                                Rd_Ready <= '0';
                            end if;
                        end if;
                        wait until rising_edge(Clk);
                        exit when Rd_Valid = '1' and Rd_Ready = '1';
                    end loop;

                    if i = 0 and w = 0 then
                        RdFirst <= Cycle;
                    end if;
                    RdLast <= Cycle;

                    -- Bytes beyond the size have any value
                    for b in 0 to UserBytes_c-1 loop
                        Byte_v := w*UserBytes_c+b;
                        if Byte_v < Cmd_v.Size then
                            check_equal(to_integer(unsigned(Rd_Data(b*8+7 downto b*8))), RefMem_v.getByte(byteAddr(Cmd_v, Byte_v)),
                                        "Read command " & integer'image(i) & " byte " & integer'image(Byte_v));
                        end if;
                    end loop;

                    check_equal(Rd_Last, choose(w = Words_v-1, '1', '0'), "Rd_Last of read command " & integer'image(i));
                end loop;

                RdDataCnt <= i+1;
            end loop;

            Rd_Ready <= '0';
        end loop;

    end process;

    -----------------------------------------------------------------------------------------------
    -- Response checks: one response per command, in command order, failed exactly when expected
    -----------------------------------------------------------------------------------------------
    p_responses : process (Clk) is
        variable WrIdx_v, RdIdx_v : natural := 0;
        variable Phase_v          : natural := 0;
        variable Cmd_v            : Cmd_t;
    begin
        if rising_edge(Clk) then
            if Phase /= Phase_v then
                Phase_v := Phase;
                WrIdx_v := 0;
                RdIdx_v := 0;
            end if;
            if Wr_Done = '1' or Wr_Error = '1' then
                check(WrIdx_v < WrList_v.count, "Write response without a command");
                if WrIdx_v < WrList_v.count then
                    Cmd_v := WrList_v.get(WrIdx_v);
                    check_equal(Wr_Error = '1', Cmd_v.Error, "Wr_Error of write command " & integer'image(WrIdx_v));
                    check_equal(Wr_Done = '1', not Cmd_v.Error, "Wr_Done of write command " & integer'image(WrIdx_v));
                    if Cmd_v.Error then
                        check_equal(Wr_ErrorResp, AxiResp_SlvErr_c, "Wr_ErrorResp of write command " & integer'image(WrIdx_v));
                    end if;
                end if;
                WrIdx_v := WrIdx_v + 1;
            end if;
            if Rd_Done = '1' or Rd_Error = '1' then
                check(RdIdx_v < RdList_v.count, "Read response without a command");
                if RdIdx_v < RdList_v.count then
                    Cmd_v := RdList_v.get(RdIdx_v);
                    check_equal(Rd_Error = '1', Cmd_v.Error, "Rd_Error of read command " & integer'image(RdIdx_v));
                    check_equal(Rd_Done = '1', not Cmd_v.Error, "Rd_Done of read command " & integer'image(RdIdx_v));
                    if Cmd_v.Error then
                        check_equal(Rd_ErrorResp, AxiResp_SlvErr_c, "Rd_ErrorResp of read command " & integer'image(RdIdx_v));
                    end if;
                end if;
                RdIdx_v := RdIdx_v + 1;
            end if;
            WrRespCnt   <= WrIdx_v;
            WrRespPhase <= Phase_v;
            RdRespCnt   <= RdIdx_v;
            RdRespPhase <= Phase_v;
        end if;
    end process;

    -----------------------------------------------------------------------------------------------
    -- AXI slave: memory model, in-order, random ready and valid stalls
    -----------------------------------------------------------------------------------------------
    p_slave : process (Clk) is
        type Queue_t is array (0 to 63) of natural;

        variable AwAddr_v, AwLen_v, AwFixed_v : Queue_t;
        variable AwWr_v, AwRd_v, WBeat_v      : natural  := 0;
        variable BTime_v, BErr_v              : Queue_t;
        variable BWr_v, BRd_v                 : natural  := 0;
        variable ArAddr_v, ArLen_v, ArFixed_v : Queue_t;
        variable ArTime_v                     : Queue_t;
        variable ArWr_v, ArRd_v, RBeat_v      : natural  := 0;
        variable Seed1_v                      : positive := Seed_g + 41;
        variable Seed2_v                      : positive := 43;
        variable Word_v, Beats_v              : natural;
        variable WErr_v                       : boolean  := false;

        -- Random stall with the stall probability, random delay of 0 to maxCycles-1 clock cycles
        procedure randomStall (stall : out boolean) is
            variable R_v : real;
        begin
            stall := false;
            if StallEna then
                uniform(Seed1_v, Seed2_v, R_v);
                stall := R_v*100.0 < real(StallPercent_g);
            end if;
        end procedure;

        procedure randomDelay (maxCycles : natural; cycles : out natural) is
            variable R_v : real;
        begin
            cycles := 0;
            if StallEna then
                uniform(Seed1_v, Seed2_v, R_v);
                cycles := integer(floor(R_v*real(maxCycles)));
            end if;
        end procedure;

        variable Stall_v : boolean;
        variable Delay_v : natural;
    begin
        if rising_edge(Clk) then
            Cycle <= Cycle + 1;
            if Rst = '1' then
                AwWr_v  := 0;
                AwRd_v  := 0;
                WBeat_v := 0;
                BWr_v   := 0;
                BRd_v   := 0;
                ArWr_v  := 0;
                ArRd_v  := 0;
                RBeat_v := 0;
                WErr_v  := false;
                AwReady <= '0';
                WReady  <= '0';
                BValid  <= '0';
                ArReady <= '0';
                RValid  <= '0';
            else

                -- *** AW: check the burst and queue it ***
                if AwValid = '1' and AwReady = '1' then
                    Beats_v := to_integer(unsigned(AwLen))+1;
                    check_equal(AwSize, toUslv(log2(AxiBytes_c), 3), "AwSize");
                    check(AwBurst = AxiBurst_Incr_c or AwBurst = AxiBurst_Fixed_c, "AwBurst");
                    check(to_integer(unsigned(AwAddr)) mod AxiBytes_c = 0, "AwAddr not aligned");
                    if AwBurst = AxiBurst_Fixed_c then
                        check(Beats_v <= FixedMaxBeats_c, "FIXED write burst too long");
                    else
                        check(Beats_v <= AxiMaxBeats_g, "Write burst too long");
                        check(to_integer(unsigned(AwAddr)) / 4096 = (to_integer(unsigned(AwAddr))+Beats_v*AxiBytes_c-1) / 4096,
                              "Write burst crosses 4 KB");
                    end if;
                    AwAddr_v(AwWr_v mod 64)  := to_integer(unsigned(AwAddr));
                    AwLen_v(AwWr_v mod 64)   := Beats_v;
                    AwFixed_v(AwWr_v mod 64) := choose(AwBurst = AxiBurst_Fixed_c, 1, 0);
                    AwWr_v                   := AwWr_v + 1;
                end if;
                randomStall(Stall_v);
                AwReady <= '0' when Stall_v else '1';

                -- *** W: write the memory (after the AW of the burst) ***
                if WValid = '1' and WReady = '1' then
                    if AwFixed_v(AwRd_v mod 64) = 1 then
                        Word_v := AwAddr_v(AwRd_v mod 64);
                    else
                        Word_v := AwAddr_v(AwRd_v mod 64) + WBeat_v*AxiBytes_c;
                    end if;
                    check(Word_v+AxiBytes_c <= MemBytes_c, "Write outside the memory");
                    if Word_v+AxiBytes_c <= MemBytes_c then

                        for b in 0 to AxiBytes_c-1 loop
                            if WStrb(b) = '1' then
                                SlaveMem_v.setByte(Word_v+b, to_integer(unsigned(WData(b*8+7 downto b*8))));
                            end if;
                        end loop;

                    end if;
                    WErr_v  := WErr_v or inErrWindow(Word_v);
                    WBeat_v := WBeat_v + 1;
                    check_equal(WLast, choose(WBeat_v = AwLen_v(AwRd_v mod 64), '1', '0'), "WLast");
                    if WBeat_v = AwLen_v(AwRd_v mod 64) then
                        randomDelay(5, Delay_v);
                        BTime_v(BWr_v mod 64) := Cycle + Delay_v;
                        BErr_v(BWr_v mod 64)  := choose(WErr_v, 1, 0);
                        BWr_v                 := BWr_v + 1;
                        AwRd_v                := AwRd_v + 1;
                        WBeat_v               := 0;
                        WErr_v                := false;
                    end if;
                end if;
                randomStall(Stall_v);
                WReady <= '1' when AwRd_v < AwWr_v and not Stall_v else '0';

                -- *** B: in order, after a random delay ***
                if BValid = '1' and BReady = '1' then
                    BRd_v := BRd_v + 1;
                end if;
                BValid <= '0';
                randomStall(Stall_v);
                if BRd_v < BWr_v and Cycle >= BTime_v(BRd_v mod 64) and not Stall_v then
                    BValid <= '1';
                    BResp  <= AxiResp_SlvErr_c when BErr_v(BRd_v mod 64) = 1 else AxiResp_Okay_c;
                end if;

                -- *** AR: check the burst and queue it ***
                if ArValid = '1' and ArReady = '1' then
                    Beats_v := to_integer(unsigned(ArLen))+1;
                    check_equal(ArSize, toUslv(log2(AxiBytes_c), 3), "ArSize");
                    check(to_integer(unsigned(ArAddr)) mod AxiBytes_c = 0, "ArAddr not aligned");
                    if ArBurst = AxiBurst_Fixed_c then
                        check(Beats_v <= FixedMaxBeats_c, "FIXED read burst too long");
                    else
                        check_equal(ArBurst, AxiBurst_Incr_c, "ArBurst");
                        check(Beats_v <= AxiMaxBeats_g, "Read burst too long");
                        check(to_integer(unsigned(ArAddr)) / 4096 = (to_integer(unsigned(ArAddr))+Beats_v*AxiBytes_c-1) / 4096,
                              "Read burst crosses 4 KB");
                    end if;
                    ArAddr_v(ArWr_v mod 64)  := to_integer(unsigned(ArAddr));
                    ArLen_v(ArWr_v mod 64)   := Beats_v;
                    ArFixed_v(ArWr_v mod 64) := choose(ArBurst = AxiBurst_Fixed_c, 1, 0);
                    randomDelay(10, Delay_v);
                    ArTime_v(ArWr_v mod 64)  := Cycle + choose(StallEna, 1 + Delay_v, RdLatency_c);
                    ArWr_v                   := ArWr_v + 1;
                end if;
                randomStall(Stall_v);
                ArReady <= '0' when Stall_v else '1';

                -- *** R: in order, data from the memory, SLVERR for the beats in the error window ***
                if RValid = '1' and RReady = '1' then
                    if RBeat_v+1 = ArLen_v(ArRd_v mod 64) then
                        ArRd_v  := ArRd_v + 1;
                        RBeat_v := 0;
                    else
                        RBeat_v := RBeat_v + 1;
                    end if;
                end if;
                RValid <= '0';
                randomStall(Stall_v);
                if ArRd_v < ArWr_v and Cycle >= ArTime_v(ArRd_v mod 64) and not Stall_v then
                    if ArFixed_v(ArRd_v mod 64) = 1 then
                        Word_v := ArAddr_v(ArRd_v mod 64);
                    else
                        Word_v := ArAddr_v(ArRd_v mod 64) + RBeat_v*AxiBytes_c;
                    end if;
                    check(Word_v+AxiBytes_c <= MemBytes_c, "Read outside the memory");
                    RValid <= '1';
                    RLast  <= choose(RBeat_v+1 = ArLen_v(ArRd_v mod 64), '1', '0');
                    RResp  <= AxiResp_SlvErr_c when inErrWindow(Word_v) else AxiResp_Okay_c;

                    for b in 0 to AxiBytes_c-1 loop
                        if Word_v+b < MemBytes_c then
                            RData(b*8+7 downto b*8) <= toUslv(SlaveMem_v.getByte(Word_v+b), 8);
                        end if;
                    end loop;

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
    i_dut : entity olo.olo_axi_master_full
        generic map (
            AxiAddrWidth_g             => AxiAddrWidth_c,
            AxiDataWidth_g             => AxiDataWidth_g,
            AxiMaxBeats_g              => AxiMaxBeats_g,
            AxiMaxOpenTransactions_g   => MaxOpen_c,
            UserTransactionSizeBits_g  => SizeBits_c,
            DataFifoDepth_g            => DataFifoDepth_c,
            UserDataWidth_g            => UserDataWidth_g
        )
        port map (
            Clk           => Clk,
            Rst           => Rst,
            CmdWr_Addr    => CmdWr_Addr,
            CmdWr_Size    => CmdWr_Size,
            CmdWr_LowLat  => CmdWr_LowLat,
            CmdWr_Fixed   => CmdWr_Fixed,
            CmdWr_Valid   => CmdWr_Valid,
            CmdWr_Ready   => CmdWr_Ready,
            CmdRd_Addr    => CmdRd_Addr,
            CmdRd_Size    => CmdRd_Size,
            CmdRd_LowLat  => CmdRd_LowLat,
            CmdRd_Fixed   => CmdRd_Fixed,
            CmdRd_Valid   => CmdRd_Valid,
            CmdRd_Ready   => CmdRd_Ready,
            Wr_Data       => Wr_Data,
            Wr_Valid      => Wr_Valid,
            Wr_Ready      => Wr_Ready,
            Rd_Data       => Rd_Data,
            Rd_Last       => Rd_Last,
            Rd_Valid      => Rd_Valid,
            Rd_Ready      => Rd_Ready,
            Wr_Done       => Wr_Done,
            Wr_Error      => Wr_Error,
            Wr_ErrorResp  => Wr_ErrorResp,
            Rd_Done       => Rd_Done,
            Rd_Error      => Rd_Error,
            Rd_ErrorResp  => Rd_ErrorResp,
            M_Axi_AwAddr  => AwAddr,
            M_Axi_AwLen   => AwLen,
            M_Axi_AwSize  => AwSize,
            M_Axi_AwBurst => AwBurst,
            M_Axi_AwValid => AwValid,
            M_Axi_AwReady => AwReady,
            M_Axi_WData   => WData,
            M_Axi_WStrb   => WStrb,
            M_Axi_WLast   => WLast,
            M_Axi_WValid  => WValid,
            M_Axi_WReady  => WReady,
            M_Axi_BResp   => BResp,
            M_Axi_BValid  => BValid,
            M_Axi_BReady  => BReady,
            M_Axi_ArAddr  => ArAddr,
            M_Axi_ArLen   => ArLen,
            M_Axi_ArSize  => ArSize,
            M_Axi_ArBurst => ArBurst,
            M_Axi_ArValid => ArValid,
            M_Axi_ArReady => ArReady,
            M_Axi_RData   => RData,
            M_Axi_RResp   => RResp,
            M_Axi_RLast   => RLast,
            M_Axi_RValid  => RValid,
            M_Axi_RReady  => RReady
        );

end architecture;
