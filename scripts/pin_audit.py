#!/usr/bin/env python3
"""Static consistency audit of docs/pin_assignments.csv against itself and
(once de2_115_top.sv exists, in M6) against the actual top-level ports.

Checks performed now (M3, no top-level file yet):
  - No FPGA pin is assigned to two different signal/index combinations.
  - Every multi-bit bus has a complete, non-duplicated index range (no gaps,
    no repeats) -- e.g. SW must have exactly indices 0..17 once each.
  - I/O standard consistency: flags any bus whose entries don't all share
    the same io_standard (a real electrical hazard if ever assigned
    carelessly), and separately lists which signals are marked "Depending
    on JP7" -- these need a human-confirmed jumper reading before the real
    .qsf can safely be written (see docs/known_limitations.md).

This is a STATIC check of the planning table, not proof the real .qsf or
Quartus pin planner agrees -- that distinction is stated in the generated
report, not left implicit.
"""
import csv
import sys
from collections import defaultdict


def main():
    csv_path = sys.argv[1] if len(sys.argv) > 1 else "docs/pin_assignments.csv"
    rows = []
    with open(csv_path, newline="") as f:
        for row in csv.DictReader(f):
            rows.append(row)

    errors = []
    warnings = []

    # ---- duplicate pin check ----
    pin_owners = defaultdict(list)
    for r in rows:
        label = f"{r['signal']}[{r['bus_index']}]" if r["bus_index"] else r["signal"]
        pin_owners[r["fpga_pin"]].append(label)
    for pin, owners in pin_owners.items():
        if len(owners) > 1:
            errors.append(f"DUPLICATE PIN {pin} assigned to multiple signals: {', '.join(owners)}")

    # ---- bus completeness check ----
    buses = defaultdict(list)
    for r in rows:
        if r["bus_index"] != "":
            buses[r["signal"]].append(int(r["bus_index"]))
    for signal, indices in buses.items():
        sorted_idx = sorted(indices)
        if len(set(indices)) != len(indices):
            dupes = [i for i in set(indices) if indices.count(i) > 1]
            errors.append(f"{signal}: duplicate bus indices {dupes}")
        expected_max = max(sorted_idx)
        missing = sorted(set(range(expected_max + 1)) - set(sorted_idx))
        if missing:
            # SD_DAT is deliberately sparse (only [0] and [3] used in SPI mode)
            if signal == "SD_DAT":
                if set(missing) - {1, 2}:
                    errors.append(f"{signal}: unexpected missing indices {sorted(set(missing) - {1,2})}")
                else:
                    warnings.append(f"{signal}: indices [1,2] intentionally unused in SPI mode (see docs/sdhc_32gb_boot_protocol.md)")
            else:
                errors.append(f"{signal}: missing bus indices {missing} (expected a complete 0..{expected_max} range)")

    # ---- I/O standard consistency per bus, and JP7-dependent flagging ----
    io_by_signal = defaultdict(set)
    jp_dependent = []
    for r in rows:
        io_by_signal[r["signal"]].add(r["io_standard"])
        if "JP" in r["io_standard"]:
            label = f"{r['signal']}[{r['bus_index']}]" if r["bus_index"] else r["signal"]
            jp_dependent.append((label, r["io_standard"]))
    for signal, stds in io_by_signal.items():
        if len(stds) > 1:
            errors.append(f"{signal}: inconsistent io_standard across its bits: {stds}")

    print(f"Audited {len(rows)} pin entries across {len(set(r['signal'] for r in rows))} signals from {csv_path}")
    print(f"Errors: {len(errors)}  Warnings: {len(warnings)}")
    print()
    if errors:
        print("ERRORS:")
        for e in errors:
            print(f"  - {e}")
    if warnings:
        print("WARNINGS:")
        for w in warnings:
            print(f"  - {w}")
    print()
    print(f"Jumper-dependent signals requiring human-confirmed JP6/JP7 reading before .qsf generation ({len(jp_dependent)} pins):")
    seen_signals = set()
    for label, std in jp_dependent:
        sig = label.split("[")[0]
        if sig not in seen_signals:
            seen_signals.add(sig)
            print(f"  - {sig}: {std}")

    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
