# Project 1.1 – FPGA Timing Constraints and XDC Basics

## Overview

This project is a continuation of **Project 01 – Single Multiply-Accumulate (MAC) Unit**. The objective was to understand how timing constraints influence FPGA implementation and timing analysis in Xilinx Vivado.

Instead of modifying the RTL design, this project focused on defining clock constraints using an XDC (Xilinx Design Constraints) file and observing their impact on the generated timing reports.

---

## Objectives

- Learn the purpose of an XDC file.
- Create the first clock constraint in Vivado.
- Understand the relationship between clock period and operating frequency.
- Perform implementation with different timing constraints.
- Analyze timing reports using Worst Negative Slack (WNS), Total Negative Slack (TNS), Hold Slack (WHS), and Pulse Width Slack (WPWS).

---

## Clock Constraints Evaluated

### Configuration 1

```tcl
create_clock -name sys_clk -period 10.000 [get_ports clk]
```

- Clock Frequency: **100 MHz**
- Timing Status: **PASS**
- WNS: **7.592 ns**

---

### Configuration 2

```tcl
create_clock -name sys_clk -period 5.000 [get_ports clk]
```

- Clock Frequency: **200 MHz**
- Timing Status: **PASS**
- WNS: **2.592 ns**

---

## Key Observations

- Reducing the clock period decreases the available time for signal propagation.
- The MAC hardware remained unchanged; only the timing requirement was modified.
- Vivado recalculated the timing margin based on the new clock constraint.
- Positive WNS indicates that the design meets the specified timing requirements.

---


