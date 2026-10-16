---------------------------------------------------------------------------------------------------
-- Copyright (c) 2026 by Julian Schneider
-- Authors: Julian Schneider
---------------------------------------------------------------------------------------------------

---------------------------------------------------------------------------------------------------
-- Description
---------------------------------------------------------------------------------------------------
-- AXI4-Stream slave that compares every TDATA bit. The VUnit axi_stream_slave and check_axi_stream
-- compare TDATA per whole byte (TKEEP has data_length/8 bits): data narrower than 8 bits is not
-- compared at all, and the bits above the last whole byte are not compared either
-- (https://github.com/VUnit/vunit/issues/1238). This wrapper pads TDATA with zeros to whole bytes
-- before the VUnit slave, and check_axi_stream_padded pads the expected data the same way.
--
-- Usage: create the slave with data_length => padded_data_length(<data width>), instantiate
-- olo_test_axis_slave_vc with that slave and the data width, and check with
-- check_axi_stream_padded instead of check_axi_stream.

---------------------------------------------------------------------------------------------------
-- VC Package
---------------------------------------------------------------------------------------------------
library ieee;
    use ieee.std_logic_1164.all;
    use ieee.numeric_std.all;

library vunit_lib;
    context vunit_lib.vunit_context;
    context vunit_lib.com_context;
    use vunit_lib.axi_stream_pkg.all;

package olo_test_axis_slave_pkg is

    -- Data length of the VUnit slave for a data width: the data width rounded up to whole bytes
    function padded_data_length (data_width : positive) return positive;

    -- check_axi_stream with the expected data padded with zeros to the data length of the slave and
    -- the expected TSTRB padded with '1' for the partial byte (the padded bits are compared)
    procedure check_axi_stream_padded (
        signal net : inout network_t;
        axi_stream : axi_stream_slave_t;
        expected   : std_logic_vector;
        tlast      : std_logic        := '1';
        tstrb      : std_logic_vector := "";
        tuser      : std_logic_vector := "";
        msg        : string           := "";
        blocking   : boolean          := true);

end package;

package body olo_test_axis_slave_pkg is

    function padded_data_length (data_width : positive) return positive is
    begin
        return 8 * ((data_width + 7) / 8);
    end function;

    procedure check_axi_stream_padded (
        signal net : inout network_t;
        axi_stream : axi_stream_slave_t;
        expected   : std_logic_vector;
        tlast      : std_logic        := '1';
        tstrb      : std_logic_vector := "";
        tuser      : std_logic_vector := "";
        msg        : string           := "";
        blocking   : boolean          := true) is
        constant data_length_c : positive                                         := data_length(axi_stream);
        variable expected_v    : std_logic_vector(data_length_c - 1 downto 0)     := (others => '0');
        variable tstrb_v       : std_logic_vector(data_length_c / 8 - 1 downto 0) := (others => '1');
    begin
        -- The expected data must fit the slave (a wider vector would be cut silently)
        assert padded_data_length(expected'length) = data_length_c
            report "check_axi_stream_padded: " & integer'image(expected'length) & " bits expected for a slave of " &
                   integer'image(data_length_c) & " bits, " & msg
            severity failure;
        expected_v(expected'length - 1 downto 0) := expected;

        if tstrb'length = 0 then
            check_axi_stream(net, axi_stream, expected_v,
                             tlast    => tlast,
                             tuser    => tuser,
                             msg      => msg,
                             blocking => blocking);
        else
            tstrb_v(tstrb'length - 1 downto 0) := tstrb;
            check_axi_stream(net, axi_stream, expected_v,
                             tlast    => tlast,
                             tstrb    => tstrb_v,
                             tuser    => tuser,
                             msg      => msg,
                             blocking => blocking);
        end if;
    end procedure;

end package body;

---------------------------------------------------------------------------------------------------
-- Component Implementation
---------------------------------------------------------------------------------------------------
library ieee;
    use ieee.std_logic_1164.all;
    use ieee.numeric_std.all;

library vunit_lib;
    context vunit_lib.vunit_context;
    context vunit_lib.com_context;
    use vunit_lib.axi_stream_pkg.all;

library work;
    use work.olo_test_axis_slave_pkg.all;

entity olo_test_axis_slave_vc is
    generic (
        slave      : axi_stream_slave_t;
        data_width : positive
    );
    port (
        aclk     : in    std_logic;
        areset_n : in    std_logic                                         := '1';
        tvalid   : in    std_logic;
        tready   : out   std_logic                                         := '0';
        tdata    : in    std_logic_vector(data_width - 1 downto 0);
        tlast    : in    std_logic                                         := '1';
        -- Strobes of the whole bytes of tdata (none for data narrower than 8 bits)
        tstrb    : in    std_logic_vector(data_width / 8 - 1 downto 0)     := (others => 'U');
        tuser    : in    std_logic_vector(user_length(slave) - 1 downto 0) := (others => '0')
    );
end entity;

architecture a of olo_test_axis_slave_vc is

    constant data_length_c : positive := padded_data_length(data_width);

    signal tdata_padded : std_logic_vector(data_length_c - 1 downto 0);
    signal tstrb_padded : std_logic_vector(data_length_c / 8 - 1 downto 0);

begin

    assert data_length(slave) = data_length_c
        report "olo_test_axis_slave_vc: the slave has " & integer'image(data_length(slave)) & " bits instead of " &
               integer'image(data_length_c) & " (padded_data_length(" & integer'image(data_width) & "))"
        severity failure;

    -- Zero padding of the data, '1' for the strobe of a partial byte (unless no strobes are connected)
    p_pad : process (all) is
        variable tdata_v : std_logic_vector(data_length_c - 1 downto 0);
        variable tstrb_v : std_logic_vector(data_length_c / 8 - 1 downto 0);
    begin
        tdata_v                          := (others => '0');
        tdata_v(data_width - 1 downto 0) := tdata;
        tdata_padded                     <= tdata_v;

        if is_u(tstrb) then
            tstrb_v := (others => 'U');
        else
            tstrb_v                            := (others => '1');
            tstrb_v(tstrb'length - 1 downto 0) := tstrb;
        end if;
        tstrb_padded <= tstrb_v;
    end process;

    vc_slave : entity vunit_lib.axi_stream_slave
        generic map (
            slave => slave
        )
        port map (
            aclk     => aclk,
            areset_n => areset_n,
            tvalid   => tvalid,
            tready   => tready,
            tdata    => tdata_padded,
            tlast    => tlast,
            tstrb    => tstrb_padded,
            tuser    => tuser
        );

end architecture;
