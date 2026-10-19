# OTP 29.1.2 kernel port (design B): milestones

Every milestone passes **`bin/sd-gate IMAGE LABEL`** and **`bin/sd-tla`**
before it is committed:
- L3 demo3 and demo15;
- L1 (200 cases, C4 on) and the regression replays;
- P18 / R-API-5;
- L2 core keys inside 19.3's outcome sets (all-keys differences only in
  registered `may_differ` entries, checked by `test/pbt/sd_l2_vis.escript`);
- L5 vs stock 29.1.2;
- POP1 partition scenario (`bin/sd-pop`, both orders), from milestone 3 on.

A progress report goes in `progress_reports/` at each green milestone.
Design: `port/KERNEL_PORT.md`. Decisions: `spec/DECISIONS.md`,
`spec/deviations.yml`.

| # | Milestone | Decisions / requirements | Status |
|---|---|---|---|
| 1 | **Seam and namespaces.** `global_group` seam dispatch to `s_group` (visibility via `publish/2`, `global`'s namespace = free namespace via `group_nodeup`), R-API-5 guard in `global`, `s_group` in the kernel supervisor, group namespaces with merge on nodeup | D-1, D-2, D-3/D-4, D-6 (GG1), RC1, U1 (on the merge path), R-API-5, R-TOP-3, R-NS-5 | **done**: 2e1b6dc, report 04 |
| 2 | **Partition harness.** A test-only image with `iptables` and `bin/sd-pop`: a real pairwise cut inside g1 = {a, r, x}, both ends register the same name, g2 = {x, y} must be unaffected, then heal plus re-dial. Run it on milestone 1 first: it is expected to fail (divergence at r), which is the evidence for 3 | POP1 acceptance test, P8 | **done** (the test exists). Milestone 2 fixes nothing: it proved the problem. On the milestone-1 kernel, the x-first order **failed**, with r keeping a's pid permanently while a and x converged on x's pid (the a-first order passed only by pid-ordering luck). Fixed in milestone 3, where both orders pass. `bin/sd-pop` is part of `bin/sd-gate` from milestone 3 on |
| 3 | **POP1 and the per-group merge, together.** On losing a fellow member, per-group `lost` reports and logical removal from that group's in-sync set (links stay up), with link incarnations against stale reports. Name operations lock and multicast within the in-sync set. On heal: a merge of the two partitions under a joint lock, which requires full connectivity, plus U1 / name-conflict resolution (19.3 uses `global:random_exit_name/3`), and retries for maximality. Coupled because POP1 creates the partitions that only the merge heals | POP1, R-NS-1, R-NS-2, U1; models `SGroupPOP*`, `SGroupMerge` (stock mode) | **done**: report 05 |
| 4 | **Hardening.** `-rsconfig` persistence (R-PERS-1, patch 0003), H2 / R-HID-1 probe (`sd_pbt_h2`, shown to detect 19.3's divergence), crash and restart (demos), and an assertion in `bin/sd-pop` that POP1 never cuts a link | R-PERS-1, R-HID-1 (M1 deferred by the user) | **done**: gate m4 green (rsconfig 3/3 at 0 ms, where 19.3 managed 0/3; H2 conforms; POP pass with links intact) |
| 5 | **Acceptance and handover.** `bin/sd-accept` on the kernel image, a rebase check (apply the patches to a newer 29.x tag), final report | | planned |

Changes to this plan are recorded here, with the reason.
- 2026-10-17: POP1 (was step 4) and the R-NS-1 merge (was step 3) were merged
  into milestone 3. In this design, the merge is the only way out of a POP1
  partition.
- 2026-10-19: milestone 3's first build deadlocked kernel boot
  (`timer:send_interval/2` in `s_group:init/1`; `timer_server` starts after
  the kernel children). Found by the image build itself, which compiles with
  the patched kernel. Fixed with a self-re-arming `erlang:send_after/3`.

