# TLA+ models (verification layer L6)

`SGroupNames.tla` models asynchronous name replication within one s_group, a
detail the RELEASE semantics (D3.3 ch. 4) abstracts away. It encodes the
mechanism hypothesised for deviation **O5**: a pairwise `global` sync exchanges
a snapshot taken at sync *start*, while `known` grows at sync *finish*, so a
registration multicast in between misses the peer forever.

| config | models | expected | result (`bin/sd-tla`) |
|---|---|---|---|
| `SGroupNames_none.cfg` | hypothesised 19.3 behaviour | `NamespaceConvergence` violated | violated (7-state trace: register on n1 while n1↔n3 sync is in flight) |
| `SGroupNames_lock.cfg` | registration excluded during the registrant's in-flight syncs | pass | pass, 2,202 distinct states |
| `SGroupNames_backfill.cfg` | sync completion sends the *current* table | pass | pass, 4,974 distinct states |

Scope and honesty:
- 3 members and 2 names. The group already exists. There are no failures and no
  membership changes.
- The model reproduces the *shape* of O5, and is consistent with the measured
  15% never-converge rate and with "fine before any sync or after all syncs".
  It has **not** yet been tied line-by-line to `global.erl` (0fdfcf28). That
  correspondence check is the next step, and it decides which fix a port adopts.
- Both fixes keep `KnowledgeCompletes` (liveness) under weak fairness of sync steps.
