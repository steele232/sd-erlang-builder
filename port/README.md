# Port candidates

`sdx/` is a **prototype**, not the port. It is a library-only s_group
(design B) on **stock OTP 29.1.2** with no kernel changes, built as image
`localhost/sd-erlang:29.1.2-sdx-proto` by `containers/port/Containerfile.sdx`.

Its purpose is to exercise the verification stack (`spec/VERIFICATION_STRATEGY.md`)
on a modern runtime, with *known* differences the oracles must detect:

- links between nodes that share no group are visible, not hidden (O2). This
  needs the kernel `net_kernel` publish hook;
- no transitive meshing inside a group (nodes connect explicitly instead), and
  `connect_all false` globally;
- whereis_name/2 from a non-member returns `undefined` (allowed by the O4 mapping).

By construction it avoids the 19.3 defects O5/O6, Q1-Q4 and C1 (no global
partition merge for group names, no logical disconnects).

The real port (kernel seam on OTP 25+ `global_group` callbacks) waits for
decision D-5 in `spec/DECISIONS.md`.
