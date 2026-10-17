# Experimental patches (never oracles)

Patches here are applied to the 19.3 reference only to **test a root-cause
hypothesis by intervention** and to **validate a fix design** before a port
implements it. The images they produce (`localhost/sd-erlang:19.3-exp-*`) must
never be used as the reference in any verification layer.

| patch | deviation | effect measured |
|---|---|---|
| `0001-resolved_s-broadcast-to-own-partition.patch` | O5 (and probably O6) | `sd_pbt_o5:run(25, 30000)`: 0/25 never converge, vs 13/50 on the reference. **Rejected by interleaved A/B** (`bin/sd-pbt-ab`, 10 rounds): `{not_quiescent,new_s_group}` 8/10 vs reference 1/10, p = 0.003. (An earlier non-interleaved verdict was withdrawn as methodologically invalid; the interleaved one stands) |
| `0003-resolved_s-tolerate-flat-known.patch` | C1a | `c1-seq30` crash rate 1/6 vs 4/8: incomplete, because C1b remains |
| `0004-resolved_s-c1a-c1b.patch` | C1a + C1b | `c1-seq30` crash rate 0/6 vs 4/8; interleaved confirmation and A/B pending |
| `0002-remove_nodes_check-keep-shared-nodes.patch` | Q2 | `sd_pbt_q2:run(5)`: 0/5 lost vs 5/5. L4: 4/10 vs 3/20, p = 0.14 (no significant regression). **Provisionally accepted** |

Build: `podman build --build-arg RUNTIME_IMAGE=<reference id> --build-arg PATCH=<patch>
-f containers/historical/Containerfile.experimental -t localhost/sd-erlang:19.3-exp-<name> .`

Method: every fix is judged twice. A targeted repro must improve, and the L4
campaign profile must not regress, measured **interleaved** against the
reference on the same harness version (`bin/sd-pbt-ab`). Comparisons against
reference campaigns from other sessions or harness versions are not valid. 0001's
first L4 verdict was withdrawn for exactly that reason.
