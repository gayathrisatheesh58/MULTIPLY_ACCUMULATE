# Project Report
# Project 01 - Single Multiply-Accumulate (MAC) Unit

---

## Project Information


| Project Name | Single Multiply-Accumulate (MAC) Unit |
| Project Number | 01 |
| Design Language | Verilog HDL |
| Development Tool | Xilinx Vivado ML Standard 2025.2 |
| Simulation Tool | XSim |
| Target FPGA | Xilinx Zynq-7000 (xc7z010clg400-1) |
| Verification Method | Self-checking Testbench |

---

# 1. Objective

The objective of this project is to design, simulate, synthesize, and implement a parameterized signed Multiply-Accumulate (MAC) unit using Verilog HDL.

The project serves as the foundation for understanding DSP architectures and forms the building block for future hardware accelerators such as matrix multipliers, FIR filters, systolic arrays, and CNN accelerators.

---

# 2. Design Specification

| Parameter | Value |
|-----------|------:|
| Input Width | 8 bits |
| Output Width | 17 bits |
| Data Type | Signed |
| Clock | Positive Edge Triggered |
| Reset | Synchronous Active High |
| Operation | ACC = ACC + (A × B) |

---

# 3. Functional Description

The MAC performs the following operation every positive edge of the clock.

```
ACC = ACC + (A × B)
```

where

- A and B are signed 8-bit inputs.
- The multiplication result is accumulated into a 17-bit register.
- The accumulator is cleared whenever Reset is asserted.

---

# 4. RTL Architecture

```
             +-------------------+
A ---------->|                   |
             |                   |
B ---------->|   Multiplier      |
             |      (A × B)      |
             +---------+---------+
                       |
                       v
                 +-----------+
                 |   Adder   |
                 +-----+-----+
                       |
                       v
                +--------------+
Clock --------->| Accumulator  |
Reset --------->| Register     |
                +--------------+
                       |
                       v
                     ACC
```

---

# 5. Simulation

A self-checking Verilog testbench was developed to verify the functionality of the MAC unit.


---

# 6. Simulation Results

| Parameter | Result |
|-----------|--------|
| Total Test Cases | 26 |
| PASS | 26 |
| FAIL | 0 |
| Simulation Status | PASS |

**Observation**

All functional test cases passed successfully. The MAC correctly performs signed multiplication, accumulation, and reset operations.

---

# 7. Synthesis Results

Synthesis completed successfully without any design errors.

| Parameter | Result |
|-----------|--------|
| Synthesis Status | PASS |
| Errors | 0 |
| Critical Warnings | 0 |
| Warnings | 0 |

---

# 8. FPGA Resource Utilization

| Resource | Used | Observation |
|----------|-----:|-------------|
| Slice LUTs | 77 | Very low logic utilization |
| Slice Registers (FFs) | 17 | One register per accumulator bit |
| Bonded IOB | 35 | Matches module input/output pins |
| BUFGCTRL | 1 | Single global clock buffer |
| DSP48 | Inferred | Multiplier mapped to FPGA DSP hardware (verified from synthesized schematic) |
| BRAM | 0 | No memory blocks required |

---

# 9. Resource Analysis

## Slice LUTs

The design utilizes 77 LUTs for implementing control logic, routing logic, and combinational circuitry.

Utilization remains extremely low compared to the available FPGA resources.

---

## Slice Registers

The accumulator width is 17 bits.

Therefore, 17 flip-flops are required to store the accumulator value.

This directly corresponds to the RTL declaration of the accumulator register.

---

## Bonded IOB

The total number of I/O buffers is 35.

| Signal | Count |
|---------|------:|
| clk | 1 |
| rst | 1 |
| A | 8 |
| B | 8 |
| ACC | 17 |
| **Total** | **35** |

---

## DSP

The synthesized schematic indicates that the multiplication operation is implemented using FPGA DSP resources.

Dedicated DSP hardware provides significantly better arithmetic performance than implementing multiplication using LUTs.

---

# 10. Timing Summary

Implementation completed successfully.

Current timing report indicates that no user timing constraints were specified.

| Parameter | Value |
|-----------|-------|
| Worst Negative Slack (WNS) | inf |
| Total Negative Slack (TNS) | 0.000 ns |
| Failing Endpoints | 0 |
| Total Endpoints | 51 |
| Timing Constraints | Not Specified |

### Observation

Since no XDC timing constraints were added, Vivado could not perform meaningful setup and hold timing analysis. Timing constraints will be introduced in future projects.

---

# 11. FPGA Design Flow Completed

The following stages were successfully completed.

- RTL Design
- Testbench Development
- Behavioral Simulation
- RTL Elaboration
- RTL Schematic Analysis
- Synthesis
- Resource Utilization Analysis
- Synthesized Schematic Analysis
- Implementation
- Timing Summary Review

---

# 12. Key Learning Outcomes

Through this project the following concepts were learned.

- Verilog module design
- Parameterized RTL coding
- Signed arithmetic
- Sequential logic
- Multiply-Accumulate architecture
- Self-checking testbench development
- Functional verification
- Vivado RTL elaboration
- FPGA synthesis flow
- FPGA resource utilization analysis
- Synthesized schematic interpretation
- Basic implementation flow

---

# 13. Conclusion

A parameterized signed Multiply-Accumulate (MAC) unit was successfully designed, simulated, synthesized, and implemented using Xilinx Vivado 2025.2.

The design successfully passed all functional verification tests with **26 PASS and 0 FAIL**. FPGA resource utilization remained extremely low, making this design an efficient baseline implementation for future MAC-based architectures.

This project establishes the foundation for subsequent developments including Dual MAC, Matrix Multipliers, MAC Arrays, Systolic Arrays, FIR Filters, and CNN Hardware Accelerators.

---

