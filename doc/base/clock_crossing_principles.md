<img src="../Logo.png" alt="Logo" width="400">

# Clock Crossing Principles

[Back to **Entity List**](../EntityList.md)

## Constraining

### Manual Constraining

All clock-crossings require the following constraints:

```tcl
set_max_delay -from [get_clocks <src-clock>] -to [get_clocks <dst-clock>] -datapath_only <period-of-faster-clock>
set_max_delay -from [get_clocks <dst-clock>] -to [get_clocks <src-clock>] -datapath_only <period-of-faster-clock>
```

**Note:** Automatic constraining currently only works for _AMD_ tools (_Vivado_). Manual
constraints are required for other tools.

**Note:** For using _Open Logic_ from  in Vivado, manual constraints are required for Versions prior to 2024.2.
Automatic constraining currently only works for verilog only since 2024.2.

### Automatic Constraining

For _AMD_ tools (_Vivado_) scoped constraints files exist, which automatically identify all _Open Logic_ clock-crossings
and constrain them correctly. When using the `import_sources.tcl` script to add _Open Logic_ to your project (see
[How To ...](../HowTo.md) section), the constraints are applied automatically.

To alternatively configure usage of the scoped constraints manually , follow the steps below.

1. Create an empty TCL file and add it to the Vivado project as constraint.
2. Enable the TCL file **for implementation only** (see screenshot below)
3. In the TCL file, add a single line `source <path-to-open-logic>/src/base/tcl/constraints_amd.tcl`

![auto constraining](./clock_crossings/auto_constraining.png)

## Reset Handling

Most clock crossings need logic in both clock domains to be reset if a reset in one of the two domains is detected. The
logic to transfer a reset from one clock domain to the other and ensure that both clock domains stay in reset at the
same time for at least one clock cycle before resets are released is implemented in
[olo_base_cc_reset](./olo_base_cc_reset.md), which is used within most clock crossings.

Because logic around clock crossings usually must be reset along with them, most clock crossings provide not only reset
inputs (_Xxx_RstIn_) but also reset outputs (_Xxx_RstOut_) on both clock domains. The reset input is the port through
which a reset is requested. The reset output does indicate that a reset is active on the related clock domain (because
of a reset input being requested on one or the other clock domain).

Any logic that must be reset when the clock crossing is reset shall be connected to the reset output signals
(_Xxx_RstOut_).

![Reset CC](./clock_crossings/reset_cc.png)

## Radiation Hardening

Designs for radiation environments often triplicate all registers automatically, e.g. with the Synplify attribute
`syn_radhardlevel = "tmr"` for Microchip devices. Voters between the stages of a synchronizer would add delay to the
path that determines the metastability MTBF. Therefore the synchronizer registers of all _Open Logic_ clock crossings
are excluded from automatic TMR (`syn_radhardlevel = "none"`): the tool triplicates the registers around the
synchronizers but not the synchronizers themselves. This concerns the synchronizers of
[olo_base_cc_bits](./olo_base_cc_bits.md), [olo_base_cc_reset](./olo_base_cc_reset.md),
[olo_base_reset_gen](./olo_base_reset_gen.md) and [olo_intf_sync](../intf/olo_intf_sync.md), and thus all clock
crossings built on them. Other tools ignore the attribute.

The generic _SyncTmr_g_ selects whether the synchronizers are implemented once or three times. It is available on all
entities that have a _SyncStages_g_ generic.

### Single Synchronizers

By default (_SyncTmr_g_ = false), every synchronizer is implemented once. A single-event upset of a synchronizer
register is not masked: the receiving side sees a wrong value for one clock cycle. Depending on the clock crossing, this
can lead to a wrong level for one cycle, a spurious or lost pulse or transfer (toggle-based crossings such as
[olo_base_cc_pulse](./olo_base_cc_pulse.md)), a wrong pointer value for one cycle
([olo_base_fifo_async](./olo_base_fifo_async.md)) or a spurious reset. Take this into account in the radiation analysis
of the design.

### Triplicated Synchronizers

With _SyncTmr_g_ = true, every synchronizer is implemented as three independent chains (including the input register
of [olo_base_cc_bits](./olo_base_cc_bits.md)), followed by a bitwise majority voter after the last stage. The chains are
excluded from automatic TMR as well, so there are no voters between the stages and the metastability MTBF of each chain
is the one of a single synchronizer. The voter masks an upset of a register in one of the chains. The chains carry the
same synthesis attributes as a single synchronizer, which also keep the tools from merging them. The latency does not
change; the cost is three times the synchronizer registers plus one voter per bit.

Only the synchronizers are triplicated. All other registers of the clock crossings are left to the automatic TMR of the
design. _SyncTmr_g_ = true is therefore meant for designs that use automatic TMR.

Without upsets, the behavior is the same as with single synchronizers. However, the three chains can see a change of
their input one clock cycle apart (skew between the chains, metastability), so after a change they can disagree for one
clock cycle. An upset of one of the other two chains in this cycle is not masked. If every level of the synchronized
signal is stable for at least two clock cycles of the slower clock, this does not change the result: the change only
appears one clock cycle later at the output. If a level is shorter, an upset in this cycle can have the same effect as
with a single synchronizer. The constraints (see [Constraining](#constraining)) limit the skew between the chains to
the period of the faster clock, which is what the two clock cycles are based on.

- [olo_base_cc_simple](./olo_base_cc_simple.md), [olo_base_cc_status](./olo_base_cc_status.md),
  [olo_base_cc_handshake](./olo_base_cc_handshake.md), [olo_base_cc_reset](./olo_base_cc_reset.md),
  [olo_base_reset_gen](./olo_base_reset_gen.md), [olo_base_cc_n2xn](./olo_base_cc_n2xn.md),
  [olo_base_cc_xn2n](./olo_base_cc_xn2n.md) and [olo_intf_clk_meas](../intf/olo_intf_clk_meas.md) fulfill this
  requirement by design.
- [olo_intf_i2c_master](../intf/olo_intf_i2c_master.md), [olo_intf_spi_slave](../intf/olo_intf_spi_slave.md) and
  [olo_intf_uart](../intf/olo_intf_uart.md) fulfill it within their minimum ratio between the _Clk_ frequency and the
  interface frequency, as long as the interface lines do not glitch.
- For [olo_intf_debounce](../intf/olo_intf_debounce.md), an upset during a short level has the same effect as a bounce,
  which the debouncing handles.
- [olo_base_fifo_async](./olo_base_fifo_async.md) does not need it: the Gray-coded pointers change only one bit at a
  time, so every chain sees either the old or the new pointer value and the voted value is always one of the two.
- [olo_base_cc_pulse](./olo_base_cc_pulse.md) fulfills it if the pulses are at least two clock cycles of the slower
  clock apart, which is the maximum pulse rate of the entity.
- For [olo_base_cc_bits](./olo_base_cc_bits.md) and [olo_intf_sync](../intf/olo_intf_sync.md), the user must hold every
  level of the input for at least two clock cycles of the slower clock (_Clk_ for _olo_intf_sync_) to profit from the
  full protection.

## Selection Table

Every clock crossing has certain pros and cons. The table below aims to summarize them

| Entity                                              | Async. Clocks | Data | Multi Bits | Valid (Sampled) | Ready | Reset Crossing | 100% Perf. | No RAM |
| --------------------------------------------------- | :-----------: | :--: | :--------: | :-------------: | :---: | :------------: | :--------: | :----: |
| [olo_base_cc_reset](./olo_base_cc_reset.md)         |       x       |      |            |                 |       |       x        |            |   x    |
| [olo_base_cc_bits](./olo_base_cc_bits.md)           |       x       |  x   |            |                 |       |                |     x      |   x    |
| [olo_base_cc_pulse](./olo_base_cc_pulse.md)         |       x       |      |            |        x        |       |       x        |     x      |   x    |
| [olo_base_cc_simple](./olo_base_cc_simple.md)       |       x       |  x   |     x      |        x        |       |       x        |            |   x    |
| [olo_base_cc_status](./olo_base_cc_status.md)       |       x       |  x   |     x      |                 |       |       x        |            |   x    |
| [olo_base_cc_handshake](./olo_base_cc_handshake.md) |       x       |  x   |     x      |        x        |   x   |       x        |            |   x    |
| [olo_base_fifo_async](./olo_base_fifo_async.md)     |       x       |  x   |     x      |        x        |   x   |       x        |     x      |        |
| [olo_base_cc_n2xn](./olo_base_cc_n2xn.md)           |               |  x   |     x      |        x        |   x   |                |     x      |   x    |
| [olo_base_cc_xn2n](./olo_base_cc_xn2n.md)           |               |  x   |     x      |        x        |   x   |                |     x      |   x    |

The meanings of the columns are as follows:

- Async. Clocks
  - Allows fully asynchronous (not phase locked) clocks
- Data
  - Allows transferring data (not only events)
- Multi Bits
  - Allows transferring multi-bits signals safely
- Valid (Samples)
  - Comes with a valid signal (i.e. allows transferring samples without duplication)
- Ready
  - Comes with a ready signal (i.e. supports backpressure)
- Reset Crossing
  - Contains a reset clock crossing
- 100% Perf.
  - Does not enforce any idle cycles.
- No RAM
  - Does not require any RAM resources
