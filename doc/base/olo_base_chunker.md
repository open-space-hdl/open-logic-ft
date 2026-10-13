<img src="../Logo.png" alt="Logo" width="400">

# olo_base_chunker

[Back to **Entity List**](../EntityList.md)

## Status Information

![Endpoint Badge](https://img.shields.io/endpoint?url=https://storage.googleapis.com/open-logic-badges/coverage/olo_base_chunker.json?cacheSeconds=0)
![Endpoint Badge](https://img.shields.io/endpoint?url=https://storage.googleapis.com/open-logic-badges/branches/olo_base_chunker.json?cacheSeconds=0)
![Endpoint Badge](https://img.shields.io/endpoint?url=https://storage.googleapis.com/open-logic-badges/issues/olo_base_chunker.json?cacheSeconds=0)

VHDL Source: [olo_base_chunker](../../src/base/vhdl/olo_base_chunker.vhd)

## Description

This entity splits every packet of an AXI4-Stream into chunks of _ChunkBeats_g_ beats. Every chunk is a packet of its
own and ends with _Out_Last_. If the input packet ends before a chunk is full, its last chunk is shorter: no padding is
added. The last beat of the last chunk of an input packet is additionally marked by _Out_InLast_, so the consumer knows
where the original packet ended.

Usage examples:

- Splitting long packets into frames of a protocol with a maximum frame size
- Processing a long stream in independent units of limited size (e.g. one CRC or one authentication tag per chunk)
- Cutting a continuous stream without _In_Last_ into packets of fixed size

Example for _ChunkBeats_g_ = 3 and an input packet of 7 beats (D0 to D6):

| Beat | Data | _In_Last_ | _Out_Last_ | _Out_InLast_ | Chunk        |
| :--- | :--- | :-------- | :--------- | :----------- | :----------- |
| 0    | D0   | '0'       | '0'        | '0'          | 1            |
| 1    | D1   | '0'       | '0'        | '0'          | 1            |
| 2    | D2   | '0'       | '1'        | '0'          | 1            |
| 3    | D3   | '0'       | '0'        | '0'          | 2            |
| 4    | D4   | '0'       | '0'        | '0'          | 2            |
| 5    | D5   | '0'       | '1'        | '0'          | 2            |
| 6    | D6   | '1'       | '1'        | '1'          | 3 (shorter)  |

The next beat after a beat with _Out_InLast_ = '1' starts the first chunk of the next input packet. A consumer that
needs to know whether a chunk is the first one of a packet tracks _Out_InLast_ of the previous chunk (the first chunk
after reset is the first chunk of a packet).

The chunk size is given in beats. For byte oriented data, a chunk holds _ChunkBeats_g_ x _Width_g_/8 bytes.

### Byte Enables

_In_Be_ and _Out_Be_ follow the **Trailing-Only Byte-Enable** convention (see [Conventions](../Conventions.md)): only
the last beat of an input packet may have byte enables deasserted. Because this beat always ends a chunk, every chunk
follows the convention as well. The byte enables are passed through unchanged and are not interpreted by the entity.

Byte enables are only meaningful for _Width_g_ being a multiple of 8. Leave _In_Be_ unconnected otherwise.

### Timing

The entity does not add any latency or buffering. Data, byte enables and handshaking signals are passed through
combinationally (_In_Ready_ = _Out_Ready_, _Out_Valid_ = _In_Valid_), only _Out_Last_ depends on a beat counter. Add an
[olo_base_pl_stage](./olo_base_pl_stage.md) at the input or output if a register stage is required for timing.

## Generics

| Name         | Type     | Default | Description                                                         |
| :----------- | :------- | ------- | :------------------------------------------------------------------ |
| Width_g      | positive | -       | Data width in bits                                                  |
| ChunkBeats_g | positive | -       | Number of beats of a chunk (the last chunk of a packet may be shorter) |

## Interfaces

### Control

| Name | In/Out | Length | Default | Description                                     |
| :--- | :----- | :----- | ------- | :---------------------------------------------- |
| Clk  | in     | 1      | -       | Clock                                           |
| Rst  | in     | 1      | -       | Reset input (high-active, synchronous to _Clk_) |

### Input Data

| Name     | In/Out | Length      | Default | Description                                                    |
| :------- | :----- | :---------- | ------- | :------------------------------------------------------------- |
| In_Data  | in     | _Width_g_   | -       | Input data                                                     |
| In_Be    | in     | _Width_g_/8 | all '1' | Input byte enables (Trailing-Only Byte-Enable convention)      |
| In_Valid | in     | 1           | '1'     | AXI4-Stream handshaking signal for _In_Data_                   |
| In_Ready | out    | 1           | N/A     | AXI4-Stream handshaking signal for _In_Data_                   |
| In_Last  | in     | 1           | '0'     | AXI4-Stream end of packet signaling for _In_Data_              |

### Output Data

| Name       | In/Out | Length      | Default | Description                                                                 |
| :--------- | :----- | :---------- | ------- | :-------------------------------------------------------------------------- |
| Out_Data   | out    | _Width_g_   | N/A     | Output data                                                                 |
| Out_Be     | out    | _Width_g_/8 | N/A     | Output byte enables (equal to _In_Be_)                                      |
| Out_Valid  | out    | 1           | N/A     | AXI4-Stream handshaking signal for _Out_Data_                               |
| Out_Ready  | in     | 1           | '1'     | AXI4-Stream handshaking signal for _Out_Data_                               |
| Out_Last   | out    | 1           | N/A     | End of a chunk                                                              |
| Out_InLast | out    | 1           | N/A     | End of the input packet: last beat of its last chunk (equal to _In_Last_)   |

## Architecture

A counter counts the transferred beats of the current chunk. _Out_Last_ is asserted when the counter reaches
_ChunkBeats_g_ - 1 or when _In_Last_ is asserted. The counter restarts at zero after every chunk and after reset.
