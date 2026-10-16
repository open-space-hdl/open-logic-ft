---------------------------------------------------------------------------------------------------
-- Copyright (c) 2026 by Julian Schneider
-- Authors: Julian Schneider
---------------------------------------------------------------------------------------------------

---------------------------------------------------------------------------------------------------
-- Description
---------------------------------------------------------------------------------------------------
-- Package with the bit timing helper of olo_intf_can: computes the configuration values for a clock
-- frequency, a bit rate and a sample point and checks them against the CAN 2.0 bit timing rules.
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
    use ieee.math_real.all;

---------------------------------------------------------------------------------------------------
-- Package Header
---------------------------------------------------------------------------------------------------
package olo_intf_pkg_can is

    -- Bit timing of olo_intf_can (all values in their natural units, see the Cfg_* ports)
    type CanBitTiming_t is record
        Prescaler : positive; -- clock cycles per time quantum
        Tseg1     : positive; -- PROP_SEG + PHASE_SEG1 in time quanta
        Tseg2     : positive; -- PHASE_SEG2 in time quanta
        Sjw       : positive; -- resynchronization jump width in time quanta
    end record;

    -- Bit timing for a clock frequency and a bit rate with the sample point closest to SamplePoint
    -- (fraction of the bit time). Chooses 8 to 25 time quanta per bit with the smallest bit rate error and
    -- stops with a failure if no setting meets the CAN 2.0 rules (Bosch CAN Specification 2.0 part B,
    -- section 10) within MaxRateError (fraction of the bit rate).
    function canBitTiming (
        ClkFreq      : real;
        BitRate      : real;
        SamplePoint  : real := 0.75;
        MaxRateError : real := 0.001) return CanBitTiming_t;

end package;

---------------------------------------------------------------------------------------------------
-- Package Body
---------------------------------------------------------------------------------------------------
package body olo_intf_pkg_can is

    function canBitTiming (
        ClkFreq      : real;
        BitRate      : real;
        SamplePoint  : real := 0.75;
        MaxRateError : real := 0.001) return CanBitTiming_t is
        variable Best_v      : CanBitTiming_t := (Prescaler => 1, Tseg1 => 1, Tseg2 => 1, Sjw => 1);
        variable BestErr_v   : real           := real'high;
        variable Presc_v     : integer;
        variable Err_v       : real;
        variable Tseg1_v     : integer;
        variable Tseg2_v     : integer;
        variable PhaseSeg1_v : integer;
    begin
        assert ClkFreq > 0.0 and BitRate > 0.0
            report "olo_intf_pkg_can.canBitTiming: ClkFreq and BitRate must be positive"
            severity failure;

        -- Prefer more time quanta per bit (finer synchronisation) at equal bit rate error
        for TqPerBit in 25 downto 8 loop
            Presc_v := integer(round(ClkFreq / (BitRate * real(TqPerBit))));
            if Presc_v >= 1 and Presc_v <= 1023 then
                Err_v := abs(ClkFreq / (real(Presc_v) * real(TqPerBit)) - BitRate) / BitRate;
                -- Sample point at the end of PHASE_SEG1: (1 + Tseg1) time quanta into the bit
                Tseg1_v := integer(round(SamplePoint * real(TqPerBit))) - 1;
                -- Bosch 2.0 section 10: PROP_SEG and PHASE_SEG1 1 to 8 each, PHASE_SEG2 at least the
                -- information processing time (2 time quanta) and at most 8
                Tseg1_v := maximum(2, minimum(16, Tseg1_v));
                Tseg2_v := TqPerBit - 1 - Tseg1_v;
                if Tseg2_v >= 2 and Tseg2_v <= 8 and Err_v < BestErr_v then
                    BestErr_v   := Err_v;
                    PhaseSeg1_v := minimum(8, Tseg1_v - 1);
                    Best_v      := (Prescaler => Presc_v,
                                    Tseg1     => Tseg1_v,
                                    Tseg2     => Tseg2_v,
                                    Sjw       => minimum(4, minimum(PhaseSeg1_v, Tseg2_v)));
                end if;
            end if;
        end loop;

        assert BestErr_v <= MaxRateError
            report "olo_intf_pkg_can.canBitTiming: no bit timing with 8 to 25 time quanta per bit reaches the bit rate " &
                   real'image(BitRate) & " from the clock " & real'image(ClkFreq) & " within the rate error " &
                   real'image(MaxRateError)
            severity failure;
        return Best_v;
    end function;

end package body;
