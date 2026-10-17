# Experimental patches (never oracles)

Patches here are applied to the 19.3 reference only to **test a root-cause
hypothesis by intervention** and to **validate a fix design** before a port
implements it. The images they produce (`localhost/sd-erlang:19.3-exp-*`) must
never be used as the reference in any verification layer.

| patch | deviation | effect measured |
|---|---|---|
| `0001-resolved_s-broadcast-to-own-partition.patch` | O5 (and probably O6) | `sd_pbt_o5:run(25, 30000)`: 0/25 never converge, vs 13/50 on the reference. **Rejected by L4:** `{not_quiescent,new_s_group}` in 6/10 campaign runs vs 3/20 pooled reference (p = 0.018) |
| `0002-remove_nodes_check-keep-shared-nodes.patch` | Q2 | `sd_pbt_q2:run(5)`: 0/5 lost vs 5/5. L4: 4/10 vs 3/20, p = 0.14 (no significant regression). **Provisionally accepted** |

Build: `podman build --build-arg RUNTIME_IMAGE=<reference id> --build-arg PATCH=<patch>
-f containers/historical/Containerfile.experimental -t localhost/sd-erlang:19.3-exp-<name> .`

Method: every fix is judged twice. A targeted repro must improve, and the L4
campaign profile must not regress. 0001 passed the first test and failed the
second, which is exactly the case the regression gate exists for.
