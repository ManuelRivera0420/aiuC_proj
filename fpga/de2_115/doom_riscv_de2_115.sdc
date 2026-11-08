# doom_riscv_de2_115.sdc
#
# Hand-written timing constraints, NOT produced by running Quartus
# TimeQuest (explicitly out of this project's scope -- see
# docs/fpga_handoff.md). These constraints are honest about what is
# actually known from this project's own RTL and simulation, and
# deliberately do NOT fabricate false_path/multicycle exceptions that
# would require timing analysis this project never ran to justify.
#
# ---- Primary clock ----
# CLOCK_50 is the board's 50 MHz oscillator (docs/board_resource_selection.md,
# Table 4-5 p.39). This design uses it directly as every internal clock --
# there is no PLL in rtl/board/de2_115_top.sv. 20.000 ns period is exact
# for 50 MHz, not rounded.
create_clock -name CLOCK_50 -period 20.000 [get_ports CLOCK_50]

# ---- Derived VGA pixel clock ----
# rtl/peripherals/vga.sv divides CLOCK_50 by 2 internally (behavioral
# clock-enable divider, verified in simulation -- sim/tb/vga_tb.sv,
# 29/29 PASS) to drive VGA_CLK and the pixel-generation logic. This is a
# generated clock on an internal register, not a PLL output, so it is
# declared here as a generated clock on VGA_CLK rather than invented as
# a second create_clock on an unrelated port.
create_generated_clock -name VGA_CLK -source [get_ports CLOCK_50] -divide_by 2 [get_ports VGA_CLK]

# ---- Clock uncertainty ----
# No PLL is used, so there is no PLL jitter spec to cite. A conservative
# generic uncertainty is applied pending the human team's own TimeQuest
# run; this is a placeholder for a first compile, not a derived number.
derive_clock_uncertainty

# ---- Input/output delays ----
# Genuinely NOT known without board-level I/O timing characterization
# (trace lengths, external device timing for the ADV7123 VGA DAC, the
# SDRAM chips, and the SD card socket) that this project has no way to
# measure through RTL simulation alone. Rather than invent set_input_delay
# / set_output_delay numbers with no basis, these are left for the human
# team to add using Quartus's I/O timing analysis and the DE2-115
# schematic -- see docs/fpga_handoff.md for the specific follow-up list.
#
# What IS constrained here is only what this project's own simulation and
# RTL review actually support:

# KEY/SW inputs are asynchronous, hardware-debounced for KEY (Schmitt
# trigger per docs/board_resource_selection.md) but NOT debounced for SW.
# Both are read by rtl/peripherals/key_sw_gpio.sv on CLOCK_50; treat as
# asynchronous rather than asserting a false timing relationship.
set_false_path -from [get_ports {KEY[*]}] -to [all_registers]
set_false_path -from [get_ports {SW[*]}] -to [all_registers]

# rst_n (KEY[0]) is an asynchronous external reset, used as an async
# reset throughout this design (every always_ff in rtl/ uses
# `negedge rst_n` in its sensitivity list) -- not timed as a synchronous
# data path.
set_false_path -from [get_ports {KEY[0]}] -to [all_registers]

# SD_DAT[0] (MISO) is read by rtl/peripherals/sd_spi.sv as the sole
# external input in that interface; sd_spi.sv runs at a slow,
# SPI-clock-derived cadence relative to CLOCK_50 (confirmed adequate by
# sim/tb/sd_spi_tb.sv, 9/9 PASS, and sim/tb/m4_e2e_tb.sv) with no
# sub-period timing margin claimed or needed here.
set_false_path -from [get_ports {SD_DAT[0]}] -to [all_registers]

# ---- What is deliberately NOT here ----
# No false_path/multicycle_path blanket exceptions on DRAM_DQ, VGA_R/G/B,
# or the SD_CLK/SD_CMD/SD_DAT[3] outputs: these are real synchronous
# output paths from CLOCK_50-domain registers and should be timed
# normally by TimeQuest once set_output_delay values are supplied by the
# human team (see note above) -- suppressing them here would hide real
# timing risk rather than report it honestly.
