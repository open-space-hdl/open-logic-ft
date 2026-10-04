<img src="../Logo.png" alt="Logo" width="400">

# olo_ft_cc_handshake

[Back to **Entity List**](../EntityList.md)

## Status Information

![Endpoint Badge](https://img.shields.io/endpoint?url=https://storage.googleapis.com/open-logic-badges/coverage/olo_ft_cc_handshake.json?cacheSeconds=0)
![Endpoint Badge](https://img.shields.io/endpoint?url=https://storage.googleapis.com/open-logic-badges/branches/olo_ft_cc_handshake.json?cacheSeconds=0)
![Endpoint Badge](https://img.shields.io/endpoint?url=https://storage.googleapis.com/open-logic-badges/issues/olo_ft_cc_handshake.json?cacheSeconds=0)

VHDL Source: [olo_ft_cc_handshake](../../src/ft/vhdl/olo_ft_cc_handshake.vhd)

## Description

This component is a **TMR-hardened clock crossing** with AXI-S handshaking for transferring data from one clock domain
to another one that runs at a potentially completely asynchronous clock. A single-event upset (SEU) on any flip-flop of
the crossing is masked: it neither corrupts, loses nor duplicates data and it does not lock up the handshake.

It is the fault-tolerant counterpart of [olo_base_cc_handshake](../base/olo_base_cc_handshake.md) with the same
interface and the same behavior. It implements full AXI-S handshaking but is not made for high performance. It can
transfer one data-word every _(2 + SyncStages_g) x InputClockPeriods + (2 + SyncStages_g) x OutputClockPeriods_.

For high data rates, use the ECC-protected [olo_ft_fifo_async](./olo_ft_fifo_async.md) instead. _olo_ft_cc_handshake_
is meant for low-rate transfers such as control and status words, where it needs no RAM.

This block follows the general [clock-crossing principles](../base/clock_crossing_principles.md). Read through them for
more information.

## Generics

| Name            | Type      | Default | Description                                                  |
| :-------------- | :-------- | ------- | :----------------------------------------------------------- |
| Width_g         | positive  | -       | Data width in bits.                                          |
| ReadyRstState_g | std_logic | '1'     | Controls the status of the _In_Ready_ signal in during reset.<br>Choose '1' for minimal logic on the (often timing-critical) _In_Ready_ path. |
| SyncStages_g    | positive  | 2       | Number of synchronization stages. <br />Range: 2 ... 4       |

## Interfaces

### Input Data

| Name      | In/Out | Length    | Default | Description                                                  |
| :-------- | :----- | :-------- | ------- | :----------------------------------------------------------- |
| In_Clk    | in     | 1         | -       | Input clock                                                  |
| In_RstIn  | in     | 1         | '0'     | Reset input (high-active, synchronous to _In_Clk_)           |
| In_RstOut | out    | 1         | N/A     | Reset output (see [clock-crossing principles](../base/clock_crossing_principles.md), synchronous to _In_Clk_) |
| In_Data   | in     | _Width_g_ | -       | Input data                                                   |
| In_Valid  | in     | 1         | '1'     | AXI4-Stream handshaking signal for _In_Data_                 |
| In_Ready  | out    | 1         | N/A     | AXI4-Stream handshaking signal for _In_Data_                 |

### Output Data

| Name       | In/Out | Length    | Default | Description                                                  |
| :--------- | :----- | :-------- | ------- | :----------------------------------------------------------- |
| Out_Clk    | in     | 1         | -       | Output clock                                                 |
| Out_RstIn  | in     | 1         | '0'     | Reset input (high-active, synchronous to _Out_Clk_)          |
| Out_RstOut | out    | 1         | N/A     | Reset output (see [clock-crossing principles](../base/clock_crossing_principles.md), synchronous to _Out_Clk_) |
| Out_Data   | out    | _Width_g_ | N/A     | Output data                                                  |
| Out_Valid  | out    | 1         | N/A     | AXI4-Stream handshaking signal for _Out_Data_                |
| Out_Ready  | in     | 1         | '1'     | AXI4-Stream handshaking signal for _Out_Data_                |

## Architecture

The architecture follows _olo_base_cc_handshake_: a request (_InTransaction_) is passed from the source domain to the
destination domain together with the data, and an acknowledge (_OutAck_) is passed back once the data was accepted.
The input logic only accepts new data after the acknowledge was received. On the output side, the data is held
(_OutLatched_) until _Out_Ready_ accepts it.

```text
                   In_Clk domain               :           Out_Clk domain
                                               :
In_Data  ---------------------------------> +--:-------------------+
                                            | olo_ft_cc_simple     |--> Out_Data
In_Valid --> InTransaction ---------------> |  (data + request)    |--> OutTransaction --+
               ^                            +--:-------------------+                     |
               |                               :                                         v
In_Ready <-- InLatched[A,B,C] -> vote          :      Out_Valid <-- OutLatched[A,B,C] -> vote
               ^                               :                                         |
               | InAck                         :                                         | OutAck
               +------------ olo_ft_private_cc_toggle <----------------------------------+
```

- **Input side (In_Clk):** _InLatched_ is a triplicated register with voter. It is set when a word is accepted and
  cleared by the acknowledge. When neither happens, every copy reloads the voted value.
- **Forward path:** [olo_ft_cc_simple](./olo_ft_cc_simple.md) transfers the data together with the request. It also
  contains the reset crossing.
- **Output side (Out_Clk):** _OutLatched_ is a triplicated register with voter that holds the valid state while
  _Out_Ready_ is low. The data itself is held by the output registers of _olo_ft_cc_simple_.
- **Acknowledge path:** [olo_ft_private_cc_toggle](./olo_ft_private_cc_toggle.md), the TMR toggle synchronizer that is
  also used inside _olo_ft_cc_simple_. It uses the already crossed resets, so no second reset crossing is required.

The latency in clock cycles is identical to _olo_base_cc_handshake_.

## Fault Tolerance

### Protection Concept

The request/acknowledge scheme is sensitive to upsets: in an unprotected implementation a single upset of the handshake
state can drop or duplicate a word, or lock the handshake up (the input side waits for an acknowledge that never
comes). Therefore all handshake state is protected:

| State                           | Clock domain | Protection                                                   |
| :------------------------------ | :----------- | :----------------------------------------------------------- |
| _InLatched_                     | _In_Clk_     | Three copies, voted hold (an upset copy is repaired at the next edge) |
| Forward data and request        | both         | [olo_ft_cc_simple](./olo_ft_cc_simple.md)                    |
| _OutLatched_                    | _Out_Clk_    | Three copies, voted hold (an upset copy is repaired at the next edge) |
| Acknowledge toggle synchronizer | both         | [olo_ft_private_cc_toggle](./olo_ft_private_cc_toggle.md)    |
| Reset crossing                  | both         | [olo_ft_cc_reset](./olo_ft_cc_reset.md) (inside _olo_ft_cc_simple_) |

### Limitations

- TMR masks one upset per register and clock cycle. Two upsets in different copies of the same register within one
  clock cycle are not masked. Depending on the register, such a double fault can drop or duplicate a word or lock up
  the handshake until the next reset.
- The voters and the combinational logic are not triplicated (same fault model as for the other
  _olo_ft_cc_\<...\>_ entities).
- See [olo_ft_cc_simple](./olo_ft_cc_simple.md#limitations) for the protection scope of the reset crossing.

### Synthesis Attributes

The same attributes as in [olo_ft_cc_simple](./olo_ft_cc_simple.md#synthesis-attributes) are used to disable vendor
TMR insertion and to prevent the synthesis tool from merging the TMR copies.

## Constraints

The same constraints as for _olo_base_cc_handshake_ apply, see
[clock-crossing principles](../base/clock_crossing_principles.md).

Note that the scoped constraints for automatic constraining in _AMD Vivado_ are only provided for the _olo_base_
clock crossings. Constrain the clock crossings of _olo_ft_ entities manually.
