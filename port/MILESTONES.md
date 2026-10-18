# OTP 29.1.2 kernel port (design B): milestones

Every milestone passes **`bin/sd-gate IMAGE LABEL`** and **`bin/sd-tla`**
before it is committed:
- L3 demo3 and demo15;
- L1 (200 cases, C4 on) and the regression replays;
- P18 / R-API-5;
- L2 core keys inside 19.3's outcome sets (all-keys differences only in
  registered `may_differ` entries, checked by `test/pbt/sd_l2_vis.escript`);
- L5 vs stock 29.1.2.

A progress report goes in `progress_reports/` at each green milestone.
Design: `port/KERNEL_PORT.md`. Decisions: `spec/DECISIONS.md`,
`spec/deviations.yml`.

| # | Milestone | Decisions / requirements | Status |
|---|---|---|---|
| 1 | **Seam and namespaces.** `global_group` seam dispatch to `s_group` (visibility via `publish/2`, `global`'s namespace = free namespace via `group_nodeup`), R-API-5 guard in `global`, `s_group` in the kernel supervisor, group namespaces with merge on nodeup | D-1, D-2, D-3/D-4, D-6 (GG1), RC1, U1 (on the merge path), R-API-5, R-TOP-3, R-NS-5 | **done**: 2e1b6dc, report 04 |
| 2 | **Partition harness.** A test-only image with `iptables` and `bin/sd-pop`: a real pairwise cut inside g1 = {a, r, x}, both ends register the same name, g2 = {x, y} must be unaffected, then heal plus re-dial. Run it on milestone 1 first: it is expected to fail (divergence at r), which is the evidence for 3 | POP1 acceptance test, P8 | **done**. On milestone 1, order a-first passes (by pid order), and order x-first **fails**: r keeps a's pid while a and x converge on x's pid, permanently. P8 held in both. Gate addition: `bin/sd-pop` must pass both orders from milestone 3 on |
| 3 | **POP1 and the per-group merge, together.** On losing a fellow member, per-group `lost` reports and logical removal from that group's in-sync set (links stay up), with link incarnations against stale reports. Name operations lock and multicast within the in-sync set. On heal: a merge of the two partitions under a joint lock, which requires full connectivity, plus U1 / name-conflict resolution (19.3 uses `global:random_exit_name/3`), and retries for maximality. Coupled because POP1 creates the partitions that only the merge heals | POP1, R-NS-1, R-NS-2, U1; models `SGroupPOP*`, `SGroupMerge` (stock mode) | **in progress**: first implementation written and compiling, `patches/otp29-wip/0002-…patch`. **Not yet run or gated.** It is kept out of `patches/otp29/`, so the default build stays at milestone 1. To resume: copy it into `patches/otp29/`, then run `bin/sd-build-port`, `bin/sd-pop` (both orders must pass), and `bin/sd-gate` |
| 4 | **Hardening.** Failure semantics in L1 (proposal M1, needs review), crash and restart scenarios on the kernel port, `-rsconfig` persistence (R-PERS-1), attribute store (R-ATTR-1, already single), H2 / R-HID-1 check | R-PERS-1, R-HID-1, M1 | planned |
| 5 | **Acceptance and handover.** `bin/sd-accept` on the kernel image, a rebase check (apply the patches to a newer 29.x tag), final report | | planned |

Changes to this plan are recorded here, with the reason.
- 2026-10-17: POP1 (was step 4) and the R-NS-1 merge (was step 3) were merged
  into milestone 3. In this design, the merge is the only way out of a POP1
  partition.
