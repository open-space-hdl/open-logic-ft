---------------------------------------------------------------------------------------------------
-- Copyright (c) 2025 by Oliver Bruendler, Switzerland
-- Authors: Rene Brglez
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
    use olo.olo_base_pkg_array.all;
    use olo.olo_base_pkg_string.all;

---------------------------------------------------------------------------------------------------
-- Entity
---------------------------------------------------------------------------------------------------
-- vunit: run_all_in_same_sim
entity olo_base_crc_be_tb is
    generic (
        runner_cfg    : string;
        RandomStall_g : boolean  := false;
        DataWidth_g   : positive := 16;
        ByteOrder_g   : string   := "MSB_FIRST";
        CrcName_g     : string   := "CRC-8/DVB-S2"
    );
end entity;

architecture sim of olo_base_crc_be_tb is

    -----------------------------------------------------------------------------------------------
    -- Types
    -----------------------------------------------------------------------------------------------
    type CrcName_t is (
        Crc8_DvbS2,
        Crc16_DectX,
        Crc32_IsoHdlc
    );

    type CrcSettings_r is record
        name          : CrcName_t;
        polynomial    : std_logic_vector;
        initialValue  : std_logic_vector;
        bitOrder      : string;
        bitFlipOutput : boolean;
        xorOutput     : std_logic_vector;
    end record;

    -----------------------------------------------------------------------------------------------
    -- Functions
    -----------------------------------------------------------------------------------------------
    -- Get crc algorithms from https://crccalc.com
    function getCrcSettings (crcName : in string) return CrcSettings_r is
    begin
        if toUpper(crcName) = "CRC-8/DVB-S2" then
            return CrcSettings_r'(
                name          => Crc8_DvbS2,
                polynomial    => x"D5",
                initialValue  => x"00",
                bitOrder      => "MSB_FIRST",
                bitFlipOutput => false,
                xorOutput     => x"00"
            );
        elsif toUpper(crcName) = "CRC-16/DECT-X" then
            return CrcSettings_r'(
                name          => Crc16_DectX,
                polynomial    => x"0589",
                initialValue  => x"0000",
                bitOrder      => "MSB_FIRST",
                bitFlipOutput => false,
                xorOutput     => x"0000"
            );
        elsif toUpper(crcName) = "CRC-32/ISO-HDLC" then
            return CrcSettings_r'(
                name          => Crc32_IsoHdlc,
                polynomial    => x"04C11DB7",
                initialValue  => x"FFFFFFFF",
                bitOrder      => "LSB_FIRST",
                bitFlipOutput => true,
                xorOutput     => x"FFFFFFFF"
            );
        else
            assert false
                report "Error: Unsupported crcName"
                severity error;
        end if;
    end function;

    -- Get expected crc from https://crccalc.com
    function getExpectedCrc (
        input   : in string;
        crcName : in CrcName_t) return std_logic_vector is
    begin
        if (input = "02") then

            case crcName is
                when Crc8_DvbS2 => return x"7F";
                when Crc16_DectX => return x"0B12";
                when Crc32_IsoHdlc => return x"3C0C8EA1";
                when others =>
                    assert false
                        report "getExpectedCrc(): Unknown CRC name"
                        severity error;
            end case;

        elsif (input = "53AF") then

            case crcName is
                when Crc8_DvbS2 => return x"24";
                when Crc16_DectX => return x"647C";
                when Crc32_IsoHdlc => return x"9626A211";
                when others =>
                    assert false
                        report "getExpectedCrc(): Unknown CRC name"
                        severity error;
            end case;

        elsif (input = "3B7EC8") then

            case crcName is
                when Crc8_DvbS2 => return x"1E";
                when Crc16_DectX => return x"297C";
                when Crc32_IsoHdlc => return x"F37CCD99";
                when others =>
                    assert false
                        report "getExpectedCrc(): Unknown CRC name"
                        severity error;
            end case;

        elsif (input = "924CA7F1") then

            case crcName is
                when Crc8_DvbS2 => return x"F0";
                when Crc16_DectX => return x"0264";
                when Crc32_IsoHdlc => return x"64716A33";
                when others =>
                    assert false
                        report "getExpectedCrc(): Unknown CRC name"
                        severity error;
            end case;

        else
            assert false
                report "getExpectedCrc(): Unsupported input = " & input
                severity error;
        end if;
    end function;

    -----------------------------------------------------------------------------------------------
    -- Constants
    -----------------------------------------------------------------------------------------------
    constant ClkPeriod_c : time := 10 ns;

    constant CrcSettings_c : CrcSettings_r := getCrcSettings(CrcName_g);

    -- Byte enables that violate the Trailing-Only convention: a gap above the LSB, or the LSB clear for two bytes
    function nonContiguousBe return std_logic_vector is
        variable Be_v : std_logic_vector(DataWidth_g/8 - 1 downto 0) := (others => '0');
    begin
        if Be_v'length >= 3 then
            Be_v(0) := '1';
            Be_v(2) := '1';
        else
            Be_v(1) := '1';
        end if;
        return Be_v;
    end function;

    constant BeNonContiguous_c : std_logic_vector(DataWidth_g/8 - 1 downto 0) := nonContiguousBe;

    -- *** Verification Components ***
    constant AxisMaster_c : axi_stream_master_t := new_axi_stream_master (
            data_length  => DataWidth_g,
            user_length  => DataWidth_g/8,
            stall_config => new_stall_config(choose(RandomStall_g, 1.0, 0.0), 5, 10)
        );

    constant AxisSlave_c : axi_stream_slave_t := new_axi_stream_slave (
            data_length  => CrcSettings_c.polynomial'length,
            stall_config => new_stall_config(choose(RandomStall_g, 1.0, 0.0), 20, 50)
        );

    -----------------------------------------------------------------------------------------------
    -- Procedures
    -----------------------------------------------------------------------------------------------
    -- Packet 53AF in the beat layout of the configuration
    procedure pushTwoBytes (signal net : inout network_t) is
    begin
        if (DataWidth_g = 16 and ByteOrder_g = "MSB_FIRST") then
            push_axi_stream(net, AxisMaster_c, x"53AF", tuser => "11", tlast => '1');
        elsif (DataWidth_g = 16 and ByteOrder_g = "LSB_FIRST") then
            push_axi_stream(net, AxisMaster_c, x"AF53", tuser => "11", tlast => '1');
        elsif (DataWidth_g = 24 and ByteOrder_g = "MSB_FIRST") then
            push_axi_stream(net, AxisMaster_c, x"4053AF", tuser => "011", tlast => '1');
        elsif (DataWidth_g = 24 and ByteOrder_g = "LSB_FIRST") then
            push_axi_stream(net, AxisMaster_c, x"1DAF53", tuser => "011", tlast => '1');
        elsif (DataWidth_g = 32 and ByteOrder_g = "MSB_FIRST") then
            push_axi_stream(net, AxisMaster_c, x"FEB453AF", tuser => "0011", tlast => '1');
        elsif (DataWidth_g = 32 and ByteOrder_g = "LSB_FIRST") then
            push_axi_stream(net, AxisMaster_c, x"DCC4AF53", tuser => "0011", tlast => '1');
        end if;
    end procedure;

    -----------------------------------------------------------------------------------------------
    -- Interface Signals
    -----------------------------------------------------------------------------------------------
    signal Clk : std_logic := '0';
    signal Rst : std_logic := '1';

    signal In_Valid : std_logic;
    signal In_Ready : std_logic;
    signal In_Data  : std_logic_vector(DataWidth_g - 1 downto 0);
    signal In_Last  : std_logic;
    signal In_Be    : std_logic_vector(DataWidth_g/8 - 1 downto 0);

    signal Out_Ready : std_logic;
    signal Out_Valid : std_logic;
    signal Out_Crc   : std_logic_vector(CrcSettings_c.polynomial'length - 1 downto 0);

    -- In_Last and In_Be of the stimuli VC, and the values driven instead while In_Valid is '0'
    signal Vc_Last   : std_logic;
    signal Vc_Be     : std_logic_vector(DataWidth_g/8 - 1 downto 0);
    signal IdleDrive : boolean                                      := false;
    signal IdleBe    : std_logic_vector(DataWidth_g/8 - 1 downto 0) := (others => '0');

begin

    -----------------------------------------------------------------------------------------------
    -- TB Control
    -----------------------------------------------------------------------------------------------
    test_runner_watchdog(runner, 1 ms);

    p_control : process is
        variable ExpectedCrc_v : std_logic_vector(CrcSettings_c.polynomial'length - 1 downto 0);
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

            if run("Test-OneByte") then
                ----------------------------------------------------------------
                -- 02
                if (DataWidth_g = 16 and ByteOrder_g = "MSB_FIRST") then
                    push_axi_stream(net, AxisMaster_c, x"0902", tuser => "01", tlast => '1');
                elsif (DataWidth_g = 16 and ByteOrder_g = "LSB_FIRST") then
                    push_axi_stream(net, AxisMaster_c, x"6D02", tuser => "01", tlast => '1');
                elsif (DataWidth_g = 24 and ByteOrder_g = "MSB_FIRST") then
                    push_axi_stream(net, AxisMaster_c, x"979202", tuser => "001", tlast => '1');
                elsif (DataWidth_g = 24 and ByteOrder_g = "LSB_FIRST") then
                    push_axi_stream(net, AxisMaster_c, x"843502", tuser => "001", tlast => '1');
                elsif (DataWidth_g = 32 and ByteOrder_g = "MSB_FIRST") then
                    push_axi_stream(net, AxisMaster_c, x"84BF2002", tuser => "0001", tlast => '1');
                elsif (DataWidth_g = 32 and ByteOrder_g = "LSB_FIRST") then
                    push_axi_stream(net, AxisMaster_c, x"395A5402", tuser => "0001", tlast => '1');
                end if;

                ExpectedCrc_v := getExpectedCrc("02", CrcSettings_c.name);
                check_axi_stream(net, AxisSlave_c, ExpectedCrc_v, msg => "CRC(02)");

            elsif run("Test-TwoBytes") then
                ----------------------------------------------------------------
                -- 53AF
                pushTwoBytes(net);

                ExpectedCrc_v := getExpectedCrc("53AF", CrcSettings_c.name);
                check_axi_stream(net, AxisSlave_c, ExpectedCrc_v, msg => "CRC(53AF)");

            elsif run("Test-IdleLastBe") then
                -- In_Last and In_Be take any value while In_Valid is '0' (AXI4-Stream): In_Last = '1' with
                -- no byte enabled, then with non-contiguous byte enables, also in the cycles between two packets
                IdleDrive <= true;
                IdleBe    <= (others => '0');

                for i in 0 to 9 loop
                    wait until rising_edge(Clk);
                end loop;

                IdleBe <= BeNonContiguous_c;

                for i in 0 to 9 loop
                    wait until rising_edge(Clk);
                end loop;

                pushTwoBytes(net);
                pushTwoBytes(net);

                ExpectedCrc_v := getExpectedCrc("53AF", CrcSettings_c.name);
                check_axi_stream(net, AxisSlave_c, ExpectedCrc_v, msg => "CRC(53AF) after idle cycles");
                check_axi_stream(net, AxisSlave_c, ExpectedCrc_v, msg => "CRC(53AF) second packet");
                wait_until_idle(net, as_sync(AxisMaster_c));
                wait_until_idle(net, as_sync(AxisSlave_c));
                -- Back to the values of the VC for the next test
                IdleDrive <= false;

            elsif run("Test-ThreeBytes") then
                ----------------------------------------------------------------
                -- 3B7EC8
                if (DataWidth_g = 16 and ByteOrder_g = "MSB_FIRST") then
                    push_axi_stream(net, AxisMaster_c, x"3B7E", tuser => "11", tlast => '0');
                    push_axi_stream(net, AxisMaster_c, x"06C8", tuser => "01", tlast => '1');
                elsif (DataWidth_g = 16 and ByteOrder_g = "LSB_FIRST") then
                    push_axi_stream(net, AxisMaster_c, x"7E3B", tuser => "11", tlast => '0');
                    push_axi_stream(net, AxisMaster_c, x"AEC8", tuser => "01", tlast => '1');
                elsif (DataWidth_g = 24 and ByteOrder_g = "MSB_FIRST") then
                    push_axi_stream(net, AxisMaster_c, x"3B7EC8", tuser => "111", tlast => '1');
                elsif (DataWidth_g = 24 and ByteOrder_g = "LSB_FIRST") then
                    push_axi_stream(net, AxisMaster_c, x"C87E3B", tuser => "111", tlast => '1');
                elsif (DataWidth_g = 32 and ByteOrder_g = "MSB_FIRST") then
                    push_axi_stream(net, AxisMaster_c, x"F33B7EC8", tuser => "0111", tlast => '1');
                elsif (DataWidth_g = 32 and ByteOrder_g = "LSB_FIRST") then
                    push_axi_stream(net, AxisMaster_c, x"FFC87E3B", tuser => "0111", tlast => '1');
                end if;

                ExpectedCrc_v := getExpectedCrc("3B7EC8", CrcSettings_c.name);
                check_axi_stream(net, AxisSlave_c, ExpectedCrc_v, msg => "CRC(3B7EC8)");

            elsif run("Test-FourBytes") then
                ----------------------------------------------------------------
                -- 924CA7F1
                if (DataWidth_g = 16 and ByteOrder_g = "MSB_FIRST") then
                    push_axi_stream(net, AxisMaster_c, x"924C", tuser => "11", tlast => '0');
                    push_axi_stream(net, AxisMaster_c, x"A7F1", tuser => "11", tlast => '1');
                elsif (DataWidth_g = 16 and ByteOrder_g = "LSB_FIRST") then
                    push_axi_stream(net, AxisMaster_c, x"4C92", tuser => "11", tlast => '0');
                    push_axi_stream(net, AxisMaster_c, x"F1A7", tuser => "11", tlast => '1');
                elsif (DataWidth_g = 24 and ByteOrder_g = "MSB_FIRST") then
                    push_axi_stream(net, AxisMaster_c, x"924CA7", tuser => "111", tlast => '0');
                    push_axi_stream(net, AxisMaster_c, x"3B7EF1", tuser => "001", tlast => '1');
                elsif (DataWidth_g = 24 and ByteOrder_g = "LSB_FIRST") then
                    push_axi_stream(net, AxisMaster_c, x"A74C92", tuser => "111", tlast => '0');
                    push_axi_stream(net, AxisMaster_c, x"C87EF1", tuser => "001", tlast => '1');
                elsif (DataWidth_g = 32 and ByteOrder_g = "MSB_FIRST") then
                    push_axi_stream(net, AxisMaster_c, x"924CA7F1", tuser => "1111", tlast => '1');
                elsif (DataWidth_g = 32 and ByteOrder_g = "LSB_FIRST") then
                    push_axi_stream(net, AxisMaster_c, x"F1A74C92", tuser => "1111", tlast => '1');
                end if;

                ExpectedCrc_v := getExpectedCrc("924CA7F1", CrcSettings_c.name);
                check_axi_stream(net, AxisSlave_c, ExpectedCrc_v, msg => "CRC(924CA7F1)");

            end if;

            wait for 1 us;
            wait_until_idle(net, as_sync(AxisMaster_c));
            wait_until_idle(net, as_sync(AxisSlave_c));

        end loop;

        -- TB done
        test_runner_cleanup(runner);
    end process;

    -----------------------------------------------------------------------------------------------
    -- Clock
    -----------------------------------------------------------------------------------------------
    Clk <= not Clk after 0.5 * ClkPeriod_c;

    -----------------------------------------------------------------------------------------------
    -- Values of In_Last and In_Be in the cycles without a beat
    -----------------------------------------------------------------------------------------------
    In_Last <= '1' when IdleDrive and In_Valid = '0' else Vc_Last;
    In_Be   <= IdleBe when IdleDrive and In_Valid = '0' else Vc_Be;

    -----------------------------------------------------------------------------------------------
    -- DUT
    -----------------------------------------------------------------------------------------------
    i_dut : entity olo.olo_base_crc
        generic map (
            DataWidth_g     => DataWidth_g,
            Polynomial_g    => CrcSettings_c.polynomial,
            InitialValue_g  => CrcSettings_c.initialValue,
            BitOrder_g      => CrcSettings_c.bitOrder,
            ByteOrder_g     => ByteOrder_g,
            BitflipOutput_g => CrcSettings_c.bitFlipOutput,
            XorOutput_g     => CrcSettings_c.xorOutput
        )
        port map (
            Clk => Clk,
            Rst => Rst,

            In_Data  => In_Data,
            In_Valid => In_Valid,
            In_Ready => In_Ready,
            In_Last  => In_Last,
            In_Be    => In_Be,

            Out_Crc   => Out_Crc,
            Out_Valid => Out_Valid,
            Out_Ready => Out_Ready
        );

    -----------------------------------------------------------------------------------------------
    -- Verification Components
    -----------------------------------------------------------------------------------------------
    vc_stimuli : entity vunit_lib.axi_stream_master
        generic map (
            Master => AxisMaster_c
        )
        port map (
            AClk   => Clk,
            TValid => In_Valid,
            TReady => In_Ready,
            TData  => In_Data,
            TUser  => Vc_Be,
            TLast  => Vc_Last
        );

    vc_response : entity vunit_lib.axi_stream_slave
        generic map (
            Slave => AxisSlave_c
        )
        port map (
            AClk   => Clk,
            TReady => Out_Ready,
            TValid => Out_Valid,
            TData  => Out_Crc
        );

end architecture;
