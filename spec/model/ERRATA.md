# Errata: choices made transcribing D3.3 ch. 4 into `sd_model.erl`

Each entry is a place where the printed semantics is ambiguous, self-inconsistent,
or silent, together with the choice the executable model makes. RELEASE reported
finding and fixing "a couple of trivial errors in the semantic specification
itself" ([TOPLAS17] §V.iii; [AST14] §5 lists two). The fixed spec was never
published separately, so some entries may coincide with their fixes.

| ID | Rule | Printed | Model choice | Why |
|---|---|---|---|---|
| E1 | `NewFreeNodes` | `AddFreeNormalGroup(fgs, nds, nds′)` merges using the **original** `nds` | uses the NoGroup-updated `nds′` | Otherwise the NoGroup update is lost and a node keeps `gr_names = {}`, which is exactly the class of M bug [AST14] §5 reports as fixed (R7) |
| E2 | `RemoveNodes` | keeps `(nis′, ns′)` even when `nis′ = {}` | drops free groups left empty | An empty free group names no nodes; keeping it breaks state equality without changing meaning |
| E3 | `send/3`, `send/4` | defined as `whereis_name` then `send(p,m)`; silent when `p = undefined` | returns `undefined`, no state change | [AST14] §5: "the formal semantics specified that the send operation should return 'undefined'" |
| E4 | `new_s_group` | assumption A1 (unique names) | duplicate name → `error`, no change | Makes A1 checkable instead of silently violated; the generator keeps names fresh anyway |
| E5 | `add_nodes` | `{ni}⊕nis⊕nis′` (disjoint union) | nodes already in `s` are ignored | Disjoint union is undefined for overlapping sets; the implementation also ignores existing members |
| E6 | `AddConnections(ni, ni)` | not excluded | no-op | A node is not connected to itself |
| E7 | `unregister_name` by a non-member | rule's `where` clause needs membership; [AST14] says "always returns True" | `True`, no change | Follows [AST14]'s reading of the rule |
