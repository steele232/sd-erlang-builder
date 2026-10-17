# Decision brief: open questions for the SD Erlang port

These decisions belong to a human, because the evidence doesn't decide them by
itself. For each one:
- the question;
- what the RELEASE sources say (PDFs in `archive/spec-sources/`, hashes and
  URLs in `manifests/spec-sources.yml`);
- what 19.3 actually does, and how we know;
- trade-offs, and my recommendation.

Record each outcome in `spec/deviations.yml`: set the entry's `port_policy`,
then set `fidelity_target` to S, M or I.

Source shorthands:
- **D3.3**: RELEASE TR-2014-004, *Scalable SD Erlang Reliability Model*
- **AST'14**: Li & Thompson, *Improved Semantics and Implementation through PBT with QuickCheck*
- **JPDC'16**: Chechina et al., *Improving the network scalability of Erlang*
- **TOPLAS'17**: Trinder et al., *Scaling Reliably*

Quick reading order: SD_ERLANG_SPEC §1–3 (one page each) → PROPERTIES.md → this file.

---

## D-1. Should a link that predates group membership become visible? (O3)

**Question.** If two nodes were connected (hidden) *before* they share an
s_group, should the link become a normal, visible group link once they do?

**RELEASE says.**
- JPDC'16 §3.1 and Table 1: connections are "transitive within an s_group,
  non-transitive with other nodes".
- D3.3 §4.2.1 `add_nodes`: `InterConnectNodes({ni} ⊕ nis ⊕ nis′)`. All members
  end up interconnected.
- M does not model visibility at all.

**19.3 does.** The link stays hidden. `add_nodes/2` even *creates* such a link,
because it RPCs the new member before the two share a group. Evidence:
- `demo/src/sd15_scenario.erl` `step_move_node` (gw1↔edge4 hidden after the move);
- the probe in `spec/deviations.yml` O3.

**Trade-off.** Visible matches the stated design (members are transitively
connected) and avoids a surprise asymmetry. But it's a behaviour change from
19.3 that any L2 trace containing a later join will show.

**Recommendation.** Make it visible (follow S3/M), and register it as
`may_differ`. No user can reasonably depend on a member being hidden from its
own group.

## D-2. Free-node `global:register_name/2` failure value (F1)

**Question.** On a node in no s_group, should a failed `global:register_name/2`
return `no` (stock OTP) or `{no, name_or_pid_already_registered}` (19.3)?

**RELEASE says.** JPDC'16 §3 and Table 3: "Functions from module global have
identical functionality on free nodes in distributed Erlang and SD Erlang." The
stock spec is `register_name(Name, Pid) -> yes | no`.

**19.3 does.** It returns `{no, Reason}`. That's the only free-node difference
L5 found: 18/20 sequences identical, and the 2 differences are exactly this
(`test/pbt/sd_free_equiv.erl`, `test-results/pbt/free-{sd,stock}.eterm`).

**Trade-off.** Code written for stock OTP that matches `no` breaks on SD 19.3.
Code written for SD 19.3 is very unlikely to exist outside RELEASE.

**Recommendation.** Match stock, per S2's backward-compatibility goal.

## D-3 / D-4. Duplicate group names in launch configs (DN1, DN2)

**Question.** A launch config defines the same group name twice with different
members.
- **D-3:** the node is in one of them. Terminate (D3.3) or merge by union (19.3)?
- **D-4:** the node is in neither. Drop the group (D3.3) or keep the union (19.3)?

**RELEASE says.** D3.3 ch. 3.1 (pp. 9–12 of the PDF): "In case the current node
is a member of at least one s_group an error is returned and the node
terminates", and for remote duplicates "we keep a record of no s_group with
that name". The rationale given: "to inform the programmer that the
configuration for a particular node is dubious".

**19.3 does.** It merges every same-name definition by union
(`s_group:update_conf/1`). The same is true in 17.4, so this was never
implemented as written. Evidence: `test/pbt/sd_pbt_dupnames.erl`.

**Trade-off.** Union silently creates a larger group than either definition, and
can mesh nodes that were never meant to talk. Terminating is loud, but can turn
a config typo into an outage at boot.

**Recommendation.** D-3: follow D3.3 (refuse to start, with a clear error); this
is configuration validation, which belongs at boot. D-4: follow D3.3 (ignore).
Both are `may_differ`.

## D-5. `prevent_overlapping_partitions` under s_groups

**Question.** Since OTP 25, `global` actively disconnects nodes to prevent
overlapping partitions, and it's on by default. Overlapping s_groups *are*
overlapping partitions by design. Per s_group, or off for SD nodes?

**Sources.**
- OTP 25.0 release notes, OTP-17911 (marked as a potential incompatibility),
  and the original opt-in OTP-17843 in the OTP 22/23 patch releases: see the
  links at the end of this file.
- 29.1.2 `lib/kernel/src/global.erl` module docs, and
  `lib/kernel/doc/kernel_app.md#prevent_overlapping_partitions`. Read them with
  `git -C archive/release-otp.git show upstream-OTP-29.1.2:lib/kernel/src/global.erl`.
- Analysis: `spec/PORT_OTP29_FEASIBILITY.md` (seams; ~20 `global_group` call
  sites in modern `global`).

**19.3 does.** Nothing of the kind; the feature didn't exist. So 19.3 offers no
fidelity target here.

**Measured (UD1).** On free nodes, stock OTP 20 and stock 29.1.2 behave
identically on 19/20 sequences. The difference is this mechanism: one
`erlang:disconnect_node(n6, n9)` makes OTP 29's `global` cut n6 and n9 off from
*all other nodes too*. Under s_groups, "n6 is not connected to n9" is the normal
state for nodes in different groups. Left unscoped, the mechanism would tear
down exactly the overlaps SD builds.

**Trade-off.** Per-group scoping keeps the protection upstream added for good
reasons (state inconsistency that persists after partitions heal, which is the
same class as our O5/Q1). It's more work and needs a model. "Off" is easy, but
gives up a correctness fix upstream strongly advises keeping.

**Modelled (2026-10-17, `spec/tla/SGroupPOP.tla`).** "Per s_group" is
ambiguous, because one physical link carries every group its two ends share.
I modelled the stock algorithm exactly as 29.1.2 documents it, plus four
scopings, on two 5-node, 3-group topologies (a chain, and a demo-like gateway
star), with up to 2 link failures. Two invariants, checked at rest:
- **OverlapFree:** inside every group, knowledge is transitive (upstream's
  goal, per group).
- **Collateral:** a group that doesn't contain both ends of a failed link is
  untouched (P8/P12).

| Policy | OverlapFree | Collateral |
|---|---|---|
| off | ✗ | ✓ |
| stock, unscoped | ✗ | ✗ |
| per-group, physical cut | ✗ | ✗ |
| per-group, physical cut + cascade | ✓ | ✗ |
| **per-group, logical** (drop the node from *that group's* knowledge; links stay up) | ✓ | ✓ |

Two findings:
- **Stock doesn't even meet its own goal under SD topology.** It assumes the
  full mesh `connect_all` gives: a receiver that isn't linked to the failed
  node ignores the report, which leaves an overlap.
- **Any scoping that cuts physical links breaks other groups,** whether or
  not it cascades.

**Recommendation (sharpened).** Per-s_group **logical** scoping: on
`lost_connection(A, B)` for group G, members of G drop B from G's knowledge
only, and never cut the physical link.

Caveat: this is the same *mechanism* as 19.3's logical disconnect. 19.3's
defects (Q1/Q2) came from applying it across *all* groups, and requirement
R-NS-2 forbids exactly that. Not yet modelled: healing (re-sync after the link
comes back), and hidden nodes. Model those before writing code.

## D-6. Can `global_group` and s_groups coexist on one node?

**Question.** 19.3 *replaced* `global_group` with `s_group` in the kernel
supervisor (see the `kernel.erl` hunk in
`patches/reference/sd-19.3-s_group-commit.patch`). A modern port could keep
both.

**RELEASE says.** Nothing about mixing them. JPDC'16 §3.1 compares the two
designs (global groups: one group per node, static; s_groups: overlapping,
dynamic).

**Recommendation.** Mutually exclusive per node: refuse to boot if both
`global_groups` and `s_groups` are configured. Revisit only if a user needs both.

## U1. One pid under two names in one group

**Question.** After a partition merge, `global` can leave one pid registered
under two names in the same group (logged as "registered under several names";
3 occurrences in campaign logs, `test-results/pbt/crash-evidence-3`). M
forbids it (D3.3 §4.2.1 `register_name`: neither name nor pid may already be in
the namespace).

**Trade-off.** Stock `global` tolerates the same situation for the free
namespace (the `global_multi_name_action` heritage). Rejecting it needs a
deterministic resolution rule at merge time.

**Recommendation.** Follow M, and resolve at merge with the existing resolve
method (keep one name, unregister the rest). It's low-risk, and makes P4 hold
unconditionally.

## Design decisions that are already evidence-backed (confirm or overrule)

| Item | Evidence | Status |
|---|---|---|
| Port design B (topology provider on the OTP 25+ `global_group` seam + separate namespace server) over A (re-port 19.3's `global.erl`) | `spec/PORT_OTP29_FEASIBILITY.md` | recommended |
| Q2 fix (keep still-shared nodes in `remove_nodes_check`) | `patches/experimental/0002…`; targeted 0/5 vs 5/5; A/B p = 0.29 | accepted |
| Q1 fix (never logically disconnect a node that still shares another group, on join paths too) | `patches/experimental/0006…`; trigger replay 10/10 pass vs 4/10 | regression A/B pending |
| C1 fix (tolerate a flat peer list; don't reuse a bound `_SGroups`) | `patches/experimental/0004…`; interleaved 0/10 vs 6/10 (p = 0.005); A/B crash dumps 0 vs 12 | accepted |
| O5 fix must be the *whole* stock merge protocol, not a retarget | `0001` passes its repro but A/B p = 0.003 regression | 0001 rejected |
| RS1: persist every `-rsconfig` change synchronously | `test/pbt/sd_pbt_rsconfig.erl`, D3.3 ch. 2 | requirement R-PERS-1 |
| AT1: single attribute store | `test/pbt/sd_pbt_attrs.erl`, JPDC'16 §3 | requirement R-ATTR-1 |
| M1: add failure semantics to the executable model (oracle change) | `spec/proposals/M1-failures.md`, D3.3 Fig. 5.4 `node_down_up` | **needs review** (3 open questions inside) |

## Links

- RELEASE D3.3: https://www.dcs.gla.ac.uk/research/sd-erlang/release-13-d33.pdf
- Li & Thompson, AST'14: https://kar.kent.ac.uk/42307/
- JPDC'16: https://eprints.gla.ac.uk/108603
- TOPLAS'17: https://arxiv.org/abs/1704.07234
- Glasgow SD Erlang site / how-to: https://www.dcs.gla.ac.uk/research/sd-erlang/
- OTP 25.0 release (OTP-17911): https://www.erlang.org/patches/otp-25.0 and https://erlang.org/download/OTP-25.0.README
- OTP 22.3.4.25 (original opt-in OTP-17843): https://www.erlang.org/patches/OTP-22.3.4.25
