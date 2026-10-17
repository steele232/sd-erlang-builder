# SD Erlang Resurrection Service: An Implementation-Ready Technical Blueprint

## Executive summary

The most practical way to resurrect SD Erlang in 2026 is **not** to maintain a traditional long-lived Erlang/OTP fork by periodically hand-rebasing it. The better architecture is to treat SD Erlang as a **small, explicitly versioned semantic patch set over pristine upstream OTP releases**, with an automated service continuously rebuilding that patch set against new OTP tags and proving—through differential testing, property-based testing, model checking, and ordinary OTP tests—that the resulting runtime still implements the intended `s_group` semantics.

That approach is unusually well supported by the historical shape of SD Erlang. The University of Glasgow's installation documentation says that the standalone `s_group` functionality was concentrated in six Kernel files:

```text
global.erl
global_search.erl
kernel.erl
net_kernel.erl
s_group.erl
kernel.app.src
```

and explicitly says those files can be substituted into an OTP installation independently of the larger RELEASE research tree. The historical full builds are preserved as the `17.4-rebased`, `19.2-rebased`, and `19.3-rebased` branches of `release-project/otp`. citeturn30view2

That gives the project a very useful decomposition:

```text
             upstream erlang/otp
                    │
                    │ immutable OTP tag
                    ▼
        ┌─────────────────────────┐
        │ semantic SD patch stack │
        └────────────┬────────────┘
                     │
              deterministic
                 transforms
                     │
              ┌──────▼──────┐
              │ build OTP   │
              └──────┬──────┘
                     │
              ┌──────▼─────────┐
              │ semantic gates │
              │                │
              │ historical     │
              │ differential   │
              │ PropEr         │
              │ Common Test    │
              │ TLC / TLA+     │
              └──────┬─────────┘
                     │
               human review
             when semantics move
                     │
        ┌────────────▼─────────────┐
        │ signed immutable release │
        │                          │
        │ tar.gz / DEB / RPM       │
        │ OCI amd64 / arm64        │
        │ SBOM + provenance        │
        └──────────────────────────┘
```

The **historical reference implementation should be preserved before any modernization**. Glasgow documents the original build sequence, and its RELEASE D3.3 report contains an unusually valuable specification artifact: an operational semantics for fifteen `s_group` operations and an `eqc_statem` QuickCheck model used to compare the abstract state against the real runtime. The published validation used 14 nodes—12 ordinary and two hidden—and QuickCheck's default 100 cases. It found multiple errors, including implementation synchronization behavior, which is exactly the sort of latent semantic regression an AI-assisted rebase could otherwise introduce. citeturn30view3turn6view0turn6view1turn6view2

The recommended initial product therefore has **three builds**, not one:

| Track | Purpose | Publish publicly? |
|---|---|---|
| SD Erlang/OTP 17.4 historical | Earliest preserved reference and research archaeology | Yes, clearly marked archival/insecure |
| SD Erlang/OTP 19.3 historical | Last documented rebased reference and main semantic oracle | Yes, clearly marked archival/insecure |
| SD Erlang/current OTP | Supported implementation, initially OTP 29.1.2 | Yes, production candidate after validation |

OTP **29.1.2, released October 14, 2026**, is the current Erlang/OTP release as of this report; Erlang/OTP lists the tag as `OTP-29.1.2`. Elixir's current stable documentation lists **Elixir 1.20.4**, supporting OTP 27–29. Those are sensible versions for the modern orchestration service and first modern port target. citeturn27search0turn27search1turn27search5

The orchestration service itself should be Elixir. Its job is not to “let an AI rewrite OTP.” Its job is to operate a **bounded software-maintenance state machine**:

```text
discover upstream release
        ↓
archive exact SHA
        ↓
materialize clean upstream worktree
        ↓
apply known SD patch stack
        ↓
run deterministic compatibility transforms
        ↓
does it compile?
   ┌────┴────┐
  yes        no
   │          │
   │      bounded AI proposal
   │          │
   │      source allowlist
   │      no test edits
   │      no spec edits
   │      no network
   │          │
   └────┬─────┘
        ↓
OTP tests
        ↓
historical differential tests
        ↓
PropEr state-machine PBT
        ↓
TLC model checks
        ↓
fault / topology tests
        ↓
reproducibility rebuild
        ↓
human gate when required
        ↓
sign + publish
```

AI should be the **last compatibility mechanism**, not the first. Most OTP releases should go through `git apply`, structural transformations, and mechanically recognizable adaptations. AI becomes useful when upstream Kernel internals have moved enough that a human would otherwise need to understand both the new OTP implementation and the old SD modification. An AI patch may change only an approved production-source allowlist; it must never change the tests, the reference traces, the TLA+ invariants, release signing configuration, or acceptance thresholds in the same change. A changed oracle is a separate human-reviewed change.

For release distribution, Hex's **Bob the Builder** is almost exactly the operational precedent to copy. Bob polls for new Erlang and Elixir releases every fifteen minutes, publishes per-architecture OTP archives and immutable Erlang/Elixir Docker tags, currently builds amd64 and arm64, and treats published tags as immutable. citeturn24search0turn24search1 The SD service can preserve that user experience:

```text
ghcr.io/sd-erlang/erlang:29.1.2-sd.1-ubuntu-24.04
ghcr.io/sd-erlang/erlang:29.1.2-sd.1-debian-trixie
ghcr.io/sd-erlang/elixir:1.20.4-erlang-29.1.2-sd.1-debian-trixie

https://builds.sd-erlang.org/otp/amd64/ubuntu-24.04/OTP-29.1.2-sd.1.tar.gz
```

The downstream-language story should deliberately remain boring. Historical standalone SD Erlang modified Kernel Erlang code rather than introducing a new BEAM instruction set, so **Elixir, Gleam, and other languages should initially be treated as conformance consumers of the altered OTP runtime, not separately patched languages**. That is consistent with Glasgow's description of the standalone implementation. citeturn30view2 Build Elixir/Gleam smoke-test images after the Erlang image passes; do not maintain unnecessary downstream forks.

Operationally, **node discovery and s-group topology must be separated**. `s_group` answers, “which nodes belong in which communication/name domains?” It does not answer, “how did this machine learn that those nodes exist?” `libcluster` already solves discovery across static EPMD host lists, DNS, Kubernetes API/DNS, UDP gossip and custom strategies, and explicitly permits custom connection plumbing. citeturn26search2turn27search2 The correct SD integration is therefore not “let libcluster connect every discovered node”—that risks recreating the broad connectivity you are trying to avoid—but rather:

```text
Kubernetes / DNS / DO API / seed file
                │
             discover
                │
                ▼
      SD topology controller
                │
       determine intended groups
                │
                ▼
        s_group:add_nodes/2
```

The business case for the project is strongest if it preserves **native Erlang distribution semantics while replacing the all-nodes-are-equal topology assumption**. That differentiates it from Partisan. Partisan is now actively maintained, supports modern OTP, supplies pluggable overlay topologies and multiple TCP channels, and should absolutely be used as the control implementation against which SD Erlang is evaluated. citeturn13search0 The question your project can answer empirically is:

> Can a modernized `s_group` retain ordinary OTP/PID/link/monitor/distribution idioms while obtaining most of the topology scaling that would otherwise motivate an application migration to Partisan?

That is a useful research result even if the eventual answer is “use Partisan.”

There is also unusually good historical evidence that the problem itself was not imaginary. Glasgow's impact record says WhatsApp reimplemented the scalable-groups concept as **Scalable Process Groups (`spg`)**, and WhatsApp engineers later publicly described an Erlang deployment exceeding **10,000 nodes**. citeturn11search1turn29search3 Modern AtomVM has meanwhile added Erlang Distribution support, allowing microcontroller-hosted AtomVM nodes to connect to BEAM or other AtomVM nodes, making distributed-runtime topology relevant at the opposite end of the hardware spectrum as well. citeturn25search10turn25search39

My recommended first milestone is therefore very concrete:

**Preserve and reproduce 19.3, extract the minimal six-file semantic patch, recreate the published QuickCheck model in PropEr, create an executable TLA+ model, then port only that minimal patch to OTP 29.1.2 manually once. After that manual port is understood and validated, automate the transition from 29.1.2 to subsequent OTP releases.**

Do not ask an AI to perform the first modern port blindly. The first port teaches you what the actual semantic seam in contemporary `net_kernel`, `global`, and Kernel configuration has become. The automation should be designed around knowledge gained from that port.

## Historical baseline and reproducible builds

The authoritative public starting point is Glasgow's SD Erlang site:

```text
https://www.dcs.gla.ac.uk/research/sd-erlang/
https://www.dcs.gla.ac.uk/research/sd-erlang/howto.html
```

Its How To page links the three preserved branches and gives the original build instructions. citeturn30view2

The source repository is:

```text
https://github.com/release-project/otp
```

The exact documented branches are:

```text
https://github.com/release-project/otp/tree/17.4-rebased
https://github.com/release-project/otp/tree/19.2-rebased
https://github.com/release-project/otp/tree/19.3-rebased
```

The related Percept2 repository used by the full HTTPS build is:

```text
https://github.com/release-project/percept2
```

The minimal installer is historically located at:

```text
https://github.com/release-project/otp/blob/17.4-rebased/sd-install.sh
```

Glasgow explicitly describes 17.4, 19.2 and 19.3 as supported rebases and gives the clone/build procedure. The later Glasgow impact record confirms that the project was manually rebased to 19.2 and 19.3 during its maintenance period and that the project intended to automate future rebases. citeturn30view2turn11search1

**Commit-SHA caveat:** the historical branch pages and Glasgow documentation expose the branch refs but the branch-tip SHA values were not reliably exposed through the primary-source crawl used for this report. I would not invent them. Your first archival action should resolve and permanently record them:

```bash
mkdir -p archive
cd archive

git clone --mirror https://github.com/release-project/otp.git release-otp.git
cd release-otp.git

git rev-parse refs/heads/17.4-rebased
git rev-parse refs/heads/19.2-rebased
git rev-parse refs/heads/19.3-rebased

git show --no-patch --format=fuller refs/heads/17.4-rebased
git show --no-patch --format=fuller refs/heads/19.3-rebased
```

Commit the resulting values to something like:

```yaml
# manifests/historical-sources.yml
release_project_otp:
  repository: https://github.com/release-project/otp.git

  sd_17_4:
    branch: 17.4-rebased
    sha: REPLACE_WITH_OBSERVED_SHA

  sd_19_3:
    branch: 19.3-rebased
    sha: REPLACE_WITH_OBSERVED_SHA
```

From that point onward **never build the historical oracle from branch names**. Branch names are human-friendly labels; the recorded object IDs are the reproducibility anchors.

The corresponding upstream OTP tags are:

```text
OTP-17.4
OTP-19.3
```

The official OTP 17.4 page dates that release to December 2014 and still exposes the 17.4 source release; current Erlang/OTP also maintains historical release downloads. citeturn8search0turn27search1

Add upstream OTP into the mirror and preserve everything as Git bundles:

```bash
git remote add upstream https://github.com/erlang/otp.git
git fetch upstream \
  refs/tags/OTP-17.4:refs/tags/upstream-OTP-17.4 \
  refs/tags/OTP-19.3:refs/tags/upstream-OTP-19.3

git bundle create ../sd-erlang-17.4.bundle \
  refs/heads/17.4-rebased \
  refs/tags/upstream-OTP-17.4

git bundle create ../sd-erlang-19.3.bundle \
  refs/heads/19.3-rebased \
  refs/tags/upstream-OTP-19.3

sha256sum ../*.bundle > ../SHA256SUMS
```

Do the same for Percept2 if you intend to preserve the full RELEASE tree.

The original documented source build is:

```bash
git clone https://github.com/release-project/otp.git
cd otp
git checkout 19.3-rebased

git submodule init

cd lib
git clone https://github.com/release-project/percept2.git
cd ..

./otp_build autoconf
./otp_build configure
./otp_build boot -a
make
```

Those are the commands published by Glasgow. citeturn30view2

For the resurrection project, I would preserve **two historical patch lines**:

```text
full-release/
    Exact 17.4-rebased and 19.3-rebased branch state.
    Preserve research tooling/tracing/etc.

s-group-minimal/
    Only the s_group semantic modification required
    for scalable distribution.
```

Generate the initial minimal patch directly from the reference trees:

```bash
git diff \
  upstream-OTP-19.3..19.3-rebased \
  -- \
  lib/kernel/src/global.erl \
  lib/kernel/src/global_search.erl \
  lib/kernel/src/kernel.erl \
  lib/kernel/src/net_kernel.erl \
  lib/kernel/src/s_group.erl \
  lib/kernel/src/kernel.app.src \
  > ../../patches/reference/OTP-19.3-s_group.patch
```

The six paths are not conjecture: Glasgow explicitly identifies them as the files necessary for standalone `s_group` functionality. citeturn30view2

Before modernizing anything, inspect the patch semantically:

```bash
git diff --stat upstream-OTP-19.3..19.3-rebased -- lib/kernel
git log -p upstream-OTP-19.3..19.3-rebased -- lib/kernel/src/net_kernel.erl
git log -p upstream-OTP-19.3..19.3-rebased -- lib/kernel/src/global.erl
git log -p upstream-OTP-19.3..19.3-rebased -- lib/kernel/src/s_group.erl
```

Maintain a machine-readable inventory:

```yaml
# patchsets/s_group_v1.yml
id: s_group-v1
oracle: sd-erlang-19.3

production_paths:
  - lib/kernel/src/global.erl
  - lib/kernel/src/global_search.erl
  - lib/kernel/src/kernel.erl
  - lib/kernel/src/net_kernel.erl
  - lib/kernel/src/s_group.erl
  - lib/kernel/src/kernel.app.src

semantic_features:
  - overlapping_s_groups
  - group_scoped_names
  - constrained_connection_transitivity
  - dynamic_add_remove
  - restart_state
```

For historical builds, the build environment needs to be **reproducible, not current**. OTP 17's official installation guide expects the usual GNU build chain—GNU Make, GCC or Clang, Perl, ncurses development libraries, Autoconf for Git checkouts, and related build prerequisites. citeturn8search1turn8search2

A practical preservation builder is Ubuntu 14.04 because it is contemporary with OTP 17.4. A preserved Docker Hub Ubuntu 14.04 manifest has digest:

```text
ubuntu:14.04@sha256:64483f3496c1373bfd55348e88694d1c4d0c9b660dee6bfef5e12f43b9933b30
```

That OS is long out of support; the image belongs **only in an isolated historical build/test environment**, never as an Internet-facing runtime.

The important reproducibility trick is not to pretend a list of remembered 2014 package versions is authoritative. Bootstrap the environment once, record *every* installed package/version, publish that build environment itself by digest, and subsequently build only from the digest.

```dockerfile
# docker/historical/Dockerfile.bootstrap
FROM ubuntu:14.04@sha256:64483f3496c1373bfd55348e88694d1c4d0c9b660dee6bfef5e12f43b9933b30

ENV DEBIAN_FRONTEND=noninteractive
ENV LANG=C
ENV LC_ALL=C

# Trusty is archival. Do not use this image for exposed services.
RUN sed -i \
      -e 's|archive.ubuntu.com/ubuntu|old-releases.ubuntu.com/ubuntu|g' \
      -e 's|security.ubuntu.com/ubuntu|old-releases.ubuntu.com/ubuntu|g' \
      /etc/apt/sources.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends \
      build-essential \
      autoconf \
      m4 \
      perl \
      git \
      ca-certificates \
      libncurses5-dev \
      libssl-dev \
      unixodbc-dev \
      xsltproc \
      fop \
 && mkdir -p /opt/build-lock \
 && dpkg-query -W -f='${Package}=${Version}\n' \
      | LC_ALL=C sort \
      > /opt/build-lock/dpkg.lock \
 && gcc --version      > /opt/build-lock/gcc.txt \
 && make --version     > /opt/build-lock/make.txt \
 && autoconf --version > /opt/build-lock/autoconf.txt \
 && openssl version -a > /opt/build-lock/openssl.txt \
 && rm -rf /var/lib/apt/lists/*
```

Build and freeze it:

```bash
docker build \
  -f docker/historical/Dockerfile.bootstrap \
  -t ghcr.io/YOUR_ORG/sd-builder:trusty-bootstrap .

docker create --name sd-lock ghcr.io/YOUR_ORG/sd-builder:trusty-bootstrap
docker cp sd-lock:/opt/build-lock ./manifests/trusty-build-lock
docker rm sd-lock

sha256sum manifests/trusty-build-lock/*

docker push ghcr.io/YOUR_ORG/sd-builder:trusty-bootstrap
docker buildx imagetools inspect \
  ghcr.io/YOUR_ORG/sd-builder:trusty-bootstrap
```

Record the resulting **image digest plus `dpkg.lock` hash**. Those are then your exact package versions. This is materially stronger than saying “use GCC 4.x” because it captures libc, headers, OpenSSL, Autoconf, Make and every transitive package.

Build historical OTP from local bundles, rather than letting an obsolete container clone arbitrary Internet content:

```dockerfile
# docker/historical/Dockerfile.sd
ARG HISTORICAL_BUILDER
FROM ${HISTORICAL_BUILDER}

ARG SD_REF
ARG PREFIX=/opt/sd-erlang

COPY vendor/sd-erlang.bundle /src/sd-erlang.bundle

RUN git clone /src/sd-erlang.bundle /src/otp \
 && cd /src/otp \
 && git checkout --detach "${SD_REF}" \
 && ./otp_build autoconf \
 && ./otp_build configure --prefix="${PREFIX}" \
 && ./otp_build boot -a \
 && make -j"$(nproc)" \
 && make install

RUN "${PREFIX}/bin/erl" \
      -noshell \
      -eval 'io:format("~p~n",[erlang:system_info(otp_release)]),halt().'
```

Invoke with the **SHA**, not branch:

```bash
docker build \
  --build-arg HISTORICAL_BUILDER=ghcr.io/YOUR_ORG/sd-builder@sha256:... \
  --build-arg SD_REF="$SD_19_3_SHA" \
  -f docker/historical/Dockerfile.sd \
  -t sd-erlang:19.3-reference .
```

A useful build matrix is:

| Build | Source | Architecture | Role |
|---|---|---|---|
| SD 17.4 | exact `17.4-rebased` SHA | amd64 | historical oracle |
| SD 19.3 | exact `19.3-rebased` SHA | amd64 | primary historical oracle |
| OTP 29.1.2 + SD | `OTP-29.1.2` + patch ID | amd64 | first supported candidate |
| OTP 29.1.2 + SD | same | arm64 | second architecture |
| OTP 28 latest + SD | supported upstream branch | amd64/arm64 | compatibility |
| OTP 27 latest + SD | supported upstream branch | amd64/arm64 | compatibility |

Current Erlang/OTP policy supports the recent OTP lines for security maintenance, and Elixir 1.20.4 currently supports OTP 27–29, so maintaining SD against the same contemporary range is a reasonable eventual target. citeturn23search31turn27search5

The modern orchestration service should itself be pinned to:

```text
Erlang/OTP 29.1.2
Elixir 1.20.4
```

rather than sharing the historical runtime. citeturn27search0turn27search5 A simple version manifest is enough:

```toml
# mise.toml or equivalent
[tools]
erlang = "29.1.2"
elixir = "1.20.4"
```

For current build images, follow Bob's pattern: select an immutable `hexpm/elixir` image, resolve it to its OCI digest once, and commit that digest to `images.lock`. Bob explicitly treats tagged Erlang/Elixir images as immutable and publishes amd64 and arm64 variants. citeturn24search0

One legal detail matters. Erlang/OTP releases **before OTP 18 were under the Erlang Public License**, while OTP 18 onward uses Apache License 2.0. Thus your 17.4 archival distribution and your modern branch do not have identical licensing provenance. Preserve all original headers/notices and have the eventual project license review distinguish archival inherited OTP code from your new service and modern patch material. citeturn27search1

## Runtime, topology, discovery, security, and reference application

Historical SD Erlang supports both static and dynamic s-group configuration. Glasgow's reliability report shows s-groups being supplied through Kernel configuration at node launch, with tuples containing a group name, a publication/type field such as `normal`, and member nodes. It also documents dynamic group creation/addition/removal and an optional `-rsconfig` mechanism that persists a node's s-group membership for recovery after restart. citeturn30view3

For a local test, create:

```erlang
%% config/sd_groups.config
[
 {kernel,
  [
   {s_groups,
    [
     {control, normal,
      ['core1@sd.local',
       'core2@sd.local',
       'gateway@sd.local']},

     {local_ai, normal,
      ['gateway@sd.local',
       'gpu1@sd.local',
       'gpu2@sd.local']},

     {external_ai, normal,
      ['gateway@sd.local',
       'saas_connector@sd.local']}
    ]}
  ]}
].
```

Then start the nodes against the same configuration:

```bash
erl \
  -name core1@sd.local \
  -setcookie "$SD_COOKIE" \
  -config config/sd_groups

erl \
  -name gateway@sd.local \
  -setcookie "$SD_COOKIE" \
  -config config/sd_groups

erl \
  -name gpu1@sd.local \
  -setcookie "$SD_COOKIE" \
  -config config/sd_groups
```

The documented SD API includes:

```erlang
s_group:new_s_group(Name, Nodes).
s_group:add_nodes(Name, Nodes).
s_group:remove_nodes(Name, Nodes).
s_group:delete_s_group(Name).

s_group:own_s_groups().
s_group:own_nodes().
s_group:own_nodes(Name).

s_group:register_name(Group, Name, Pid).
s_group:re_register_name(Group, Name, Pid).
s_group:unregister_name(Group, Name).
s_group:registered_names({s_group, Group}).
s_group:whereis_name(Node, Group, Name).
s_group:send(Node, Group, Name, Msg).
```

Those functions are listed by Glasgow's SD Erlang documentation. citeturn30view2

The reference application should be deliberately small but semantically rich. I would build an **AI-job router**, not because AI is essential to SD Erlang, but because it naturally demonstrates heterogeneous resources and overlapping communication domains.

The business API is:

```http
POST /v1/jobs
Content-Type: application/json

{
  "idempotency_key": "01H...",
  "prompt": "...",
  "execution_policy": "prefer_local"
}
```

and:

```http
GET /v1/jobs/:id
```

The logical roles are:

```text
                         client
                            │
                            ▼
                    ┌──────────────┐
                    │   gateway    │
                    └──────┬───────┘
                           │
             ┌─────────────┼──────────────┐
             │             │              │
             │             │              │
        control group   local_ai      external_ai
             │             │              │
       ┌─────┴────┐     ┌──┴─────┐    ┌───┴─────────┐
       │ core1    │     │ gpu1   │    │ connector   │
       │ core2    │     │ gpu2   │    │ OpenAI/etc. │
       └──────────┘     └────────┘    └─────────────┘
```

`gateway` deliberately belongs to several s-groups. `gpu1` does not need a relationship with `core2` merely because both know `gateway`; `saas_connector` does not need to participate in the local GPU namespace.

Third-party AI providers themselves are obviously not Erlang nodes. The **connector BEAM node** is the s-group participant, providing an adapter to the external HTTP API.

Give both execution groups a registration called `worker_pool`:

```erlang
s_group:register_name(local_ai, worker_pool, LocalPoolPid).
s_group:register_name(external_ai, worker_pool, ExternalPoolPid).
```

That produces an excellent test of group-scoped names: identical logical names should resolve differently according to group context.

The application should not pretend that native Erlang message passing is durable delivery. A submitted job should first be written to a durable ledger—PostgreSQL, SQLite for the demo, or another appropriate store—with an idempotency key. The Erlang message then means “attempt execution for job X,” not “the only durable copy of the business operation.” That preserves the benefits of actor messaging without conflating it with Kafka-style durable delivery semantics.

The required scenarios are:

| Scenario | Expected property |
|---|---|
| Local job | gateway finds local `worker_pool` |
| External job | gateway finds external `worker_pool` |
| Same registered name | namespaces do not collide |
| Kill GPU node | failure visible only to relevant participants |
| Add GPU dynamically | `s_group:add_nodes/2` converges |
| Remove GPU | removed node ceases sharing that group's namespace |
| Kill gateway | core/local/external groups retain internal functionality |
| Restart with `-rsconfig` | membership recovers as historically specified |
| Partition unrelated groups | topology does not induce global reconnect |
| Third-party timeout | job remains recoverable from durable ledger |

The RELEASE work explicitly considered Riak, Sim-Diasca, Orbit and Mandelbrot as exemplars and proposed grouping Riak nodes according to preference-list relationships, emphasizing that different applications required different group/recovery behavior. citeturn30view3 The reference app above is intentionally modern but exercises the same concepts: local communication neighborhoods, dynamic resources, overlapping nodes and independent recovery domains.

**Discovery must remain a separate subsystem.**

`libcluster` currently supports static Erlang host lists, UDP gossip, Kubernetes API, Kubernetes DNS and custom clustering strategies; importantly, its architecture also lets users substitute distribution plumbing such as Partisan. citeturn26search2turn27search2

Do **not** do this:

```text
discover every pod
      ↓
Node.connect every pod
      ↓
oops: giant connectivity graph
```

Instead:

```text
discover node candidates
         │
         ▼
read metadata:
  role=gpu
  region=phx
  group=local_ai
         │
         ▼
TopologyController
         │
         ├─ desired group membership
         ├─ permitted seed connections
         └─ gateway relationships
         │
         ▼
s_group:add_nodes/2
```

A modern adapter API could look like:

```elixir
defmodule SdErlang.Discovery do
  @callback snapshot() ::
              {:ok,
               [
                 %{
                   node: node(),
                   labels: map(),
                   addresses: [String.t()]
                 }
               ]}
              | {:error, term()}
end
```

Then:

```elixir
defmodule SdErlang.TopologyController do
  use GenServer

  def reconcile(discovered, desired) do
    # Pure calculation first:
    # current topology -> desired operations
    #
    # Only the executor below should mutate runtime membership.
  end
end
```

For Kubernetes, a headless-service/DNS strategy is attractive because node addresses already come from cluster DNS. `libcluster` has Kubernetes DNS and API strategies specifically for this problem. citeturn26search2

For DigitalOcean without Kubernetes, use one of:

```text
small static seed list
DNS A/AAAA records
Consul
DigitalOcean API discovery
a third-party libcluster DigitalOcean strategy
```

For a five-node system, a committed/runtime-generated seed list is often better than introducing another control plane:

```elixir
config :sd_control, seeds: [
  :"gateway1@10.42.0.11",
  :"gateway2@10.42.0.12"
]
```

A joining node needs only enough information to contact a topology authority or one legitimate peer. **Discovery does not require every node to know every node.**

Security deserves special treatment because Erlang distribution's trust model is extremely powerful. Erlang's security documentation warns that ordinary connected Erlang nodes are trusted peers and recommends TLS distribution and network isolation for security-sensitive deployments; EPMD additionally exposes distribution endpoints unless constrained. citeturn7search2

For **OTP 17 and 19 historical runs**, `inet_tls_dist` already existed. OTP 17 and 19 documentation both describe `-proto_dist inet_tls`, and cookies remain part of the protocol even with TLS. citeturn31search12turn31search0

A subtle compatibility point matters: `-ssl_dist_optfile` was introduced later, around OTP 20-era SSL changes. For historical OTP 17/19, use repeated `-ssl_dist_opt` arguments; for modern OTP use the much cleaner option file. citeturn31search16turn31search17

Generate a lab CA:

```bash
mkdir -p certs
cd certs

openssl genrsa -out ca.key 4096

openssl req \
  -x509 \
  -new \
  -key ca.key \
  -sha256 \
  -days 3650 \
  -subj "/CN=SD Erlang Lab CA" \
  -out ca.crt
```

Generate one key/certificate per node:

```bash
NODE=core1.sd.local

openssl genrsa -out "${NODE}.key" 3072

openssl req \
  -new \
  -key "${NODE}.key" \
  -subj "/CN=${NODE}" \
  -out "${NODE}.csr"

cat > "${NODE}.ext" <<EOF
subjectAltName=DNS:${NODE}
extendedKeyUsage=serverAuth,clientAuth
keyUsage=digitalSignature,keyEncipherment
EOF

openssl x509 \
  -req \
  -in "${NODE}.csr" \
  -CA ca.crt \
  -CAkey ca.key \
  -CAcreateserial \
  -out "${NODE}.crt" \
  -days 825 \
  -sha256 \
  -extfile "${NODE}.ext"
```

Historical OTP 19 invocation:

```bash
erl \
  -name core1@core1.sd.local \
  -setcookie "$SD_COOKIE" \
  -proto_dist inet_tls \
  -ssl_dist_opt server_certfile '"certs/core1.sd.local.crt"' \
  -ssl_dist_opt server_keyfile '"certs/core1.sd.local.key"' \
  -ssl_dist_opt server_cacertfile '"certs/ca.crt"' \
  -ssl_dist_opt server_verify verify_peer \
  -ssl_dist_opt server_fail_if_no_peer_cert true \
  -ssl_dist_opt client_certfile '"certs/core1.sd.local.crt"' \
  -ssl_dist_opt client_keyfile '"certs/core1.sd.local.key"' \
  -ssl_dist_opt client_cacertfile '"certs/ca.crt"' \
  -ssl_dist_opt client_verify verify_peer \
  -config config/sd_groups
```

OTP 19 documents `server_`/`client_` certificate, CA, verification and `fail_if_no_peer_cert` options for `inet_tls_dist`. citeturn31search0turn31search1

I would nevertheless **never expose the OTP 17/19 historical runtime directly to an untrusted network**. Its cryptographic stack and runtime are archival software. Run those nodes on a dedicated Docker network, VM network or lab VLAN.

For modern OTP 29, use a TLS option file:

```erlang
%% config/ssl_dist.conf
[
 {server,
  [
   {certfile, "/run/secrets/node.crt"},
   {keyfile, "/run/secrets/node.key"},
   {cacertfile, "/run/secrets/ca.crt"},
   {verify, verify_peer},
   {fail_if_no_peer_cert, true}
  ]},

 {client,
  [
   {certfile, "/run/secrets/node.crt"},
   {keyfile, "/run/secrets/node.key"},
   {cacertfile, "/run/secrets/ca.crt"},
   {verify, verify_peer}
  ]}
].
```

Then:

```bash
erl \
  -name gateway@gateway.sd.internal \
  -setcookie "$SD_COOKIE" \
  -proto_dist inet_tls \
  -ssl_dist_optfile /etc/sd-erlang/ssl_dist.conf \
  -kernel inet_dist_listen_min 9100 \
          inet_dist_listen_max 9199 \
  -config /etc/sd-erlang/sd_groups
```

Modern OTP explicitly documents `inet_tls_dist`, the option-file mechanism and the continued cookie requirement. citeturn31search5

Treat the cookie as an **additional cluster secret**, not a substitute for authentication or encryption. Put the distribution port range behind a VPC/security group/firewall, restrict EPMD or replace its discovery role where feasible, and rotate node certificates separately from the cookie. Current EPMD normally provides node-name-to-distribution-port discovery, which is another reason to keep it off hostile networks. citeturn7search6turn7search9

## Verification architecture: QuickCheck, PropEr, differential semantics, and TLA+

This is the part of the project that turns an interesting fork-maintenance bot into a defensible runtime project.

The historical RELEASE team did not merely unit-test `s_group`. D3.3 defines an operational semantics for **fifteen SD Erlang functions** and validates the implementation using an `eqc_statem` model. The report says its QuickCheck environment used 14 nodes, including two hidden nodes. citeturn30view3turn6view0

The screenshots of the published test model show the recognizable QuickCheck state-machine structure:

```text
initial abstract state
command generation
precondition
next_state
postcondition
run_commands
cleanup
```

and weighted generation emphasizing create/add/remove/delete and name-registration/send operations. citeturn6view0turn6view1turn6view2

That gives the modern project four independent oracles:

```text
Historical SD 19.3 implementation
              │
              │ differential execution
              ▼
       candidate modern SD

Published operational semantics
              │
              ▼
          PropEr model

Abstract protocol
              │
              ▼
         TLA+ / TLC

OTP runtime itself
              │
              ▼
 Common Test / regression tests
```

First, search the preserved tree for the original QuickCheck source:

```bash
git grep -n -E \
  'eqc_statem|prop_s_group|new_s_group_next_state|postcondition' \
  "$SD_17_WORKTREE" \
  "$SD_19_WORKTREE"
```

If the complete suite is present, preserve it unchanged.

Running it requires a compatible QuviQ QuickCheck installation/license. If that dependency cannot legitimately be obtained, **do not silently label the PropEr reconstruction “the original tests.”** Preserve two statuses:

```text
historical_quickcheck:
    source: preserved/reconstructed
    executable: yes/no
    reason: ...

proper_port:
    executable: yes
```

The open PropEr state-machine API is extremely close structurally to `eqc_statem`: `initial_state`, `command`, `precondition`, `next_state`, `postcondition`, `commands` and `run_commands` are all directly available. citeturn19search0turn19search1

A skeleton port is:

```erlang
-module(sd_s_group_statem).

-include_lib("proper/include/proper.hrl").

-export([
    initial_state/0,
    command/1,
    precondition/2,
    next_state/3,
    postcondition/3
]).

-record(state, {
    groups = #{},
    nodes = [],
    registrations = #{}
}).

initial_state() ->
    #state{
        groups = #{},
        nodes = test_nodes(),
        registrations = #{}
    }.

command(State) ->
    proper_types:frequency([
        {5, new_group_cmd(State)},
        {5, add_nodes_cmd(State)},
        {5, remove_nodes_cmd(State)},
        {5, delete_group_cmd(State)},
        {10, register_name_cmd(State)},
        {10, reregister_name_cmd(State)},
        {10, unregister_name_cmd(State)},
        {10, whereis_name_cmd(State)},
        {10, send_cmd(State)},
        {1, node_down_up_cmd(State)}
    ]).

precondition(State, {call, ?MODULE, new_group, [Name, Nodes]}) ->
    Nodes =/= [] andalso
    allowed_new_group(State, Name, Nodes);

precondition(_State, _Call) ->
    true.

next_state(State, Result, Call) ->
    model_transition(State, Result, Call).

postcondition(State, Call, ActualResult) ->
    Expected = model_result(State, Call),
    normalize(ActualResult) =:= normalize(Expected).

prop_s_group() ->
    ?FORALL(
       Cmds,
       proper_statem:commands(?MODULE),
       begin
           ok = sd_test_cluster:reset(),
           {History, FinalState, Result} =
               proper_statem:run_commands(?MODULE, Cmds),

           ?WHENFAIL(
              io:format(
                "History: ~p~nState: ~p~nResult: ~p~n",
                [History, FinalState, Result]),
              Result =:= ok)
       end).
```

The weighting intentionally mirrors the published QuickCheck approach rather than inventing a completely different workload. citeturn6view2

Run multiple PBT tiers:

```text
PR:
    100 command sequences
    5-50 operations each
    fixed reported seed on failure

main:
    1,000 sequences
    10-200 operations

nightly:
    10,000+ sequences
    injected disconnect/reconnect
    random process death
    node death/restart

weekly:
    parallel_commands
    multi-host network faults
    latency/loss/reordering
```

Always print/store the seed:

```erlang
proper:quickcheck(
    sd_s_group_statem:prop_s_group(),
    [{numtests, 1000}, {to_file, user}]
).
```

On failure, persist:

```json
{
  "otp": "29.1.2",
  "sd_patch": "s_group-v1.4",
  "seed": "...",
  "commands": ["..."],
  "topology": "...",
  "source_sha": "...",
  "builder_digest": "sha256:..."
}
```

Then add **differential semantics**. This may be more valuable than any single hand-written test.

Run identical command traces against:

```text
Oracle A: SD Erlang 19.3
Candidate B: modern SD Erlang
```

Normalize irrelevant differences:

```text
PID values
ports
timestamps
generated UUIDs
node-local paths
ordering where semantics allow permutations
```

Compare:

```text
return values
group membership
known-node sets
registrations
resolution results
connectivity graph
post-crash recovery state
eventual convergence state
```

A simple harness protocol can be JSON or ETF over a local Unix socket:

```json
{
  "op": "add_nodes",
  "group": "local_ai",
  "nodes": ["gpu2@sd.local"]
}
```

Both runtimes execute it and return normalized observations.

The particularly important fault cases come directly from historical experience. The RELEASE report says testing uncovered several semantics/implementation problems, including timing/synchronization behavior in which removed group information could take significant time to disappear. citeturn6view2turn30view3 Therefore never assert only instantaneous state. Tests need both:

```text
immediate safety:
    nothing illegal becomes visible

eventual liveness:
    legal state converges by deadline
```

TLA+ should cover the **protocol semantics rather than BEAM implementation detail**. TLC is designed to explore state spaces and check safety/liveness properties, and PlusCal can provide a more algorithmic notation translated to TLA+. citeturn20search0turn20search2turn20search3

A deliberately compact initial model might be:

```tla
--------------------------- MODULE SGroup ---------------------------
EXTENDS Naturals, FiniteSets, Sequences

CONSTANTS Nodes, Groups, Names

VARIABLES
    alive,
    membership,
    registrations,
    connections

vars ==
    <<alive, membership, registrations, connections>>

Init ==
    /\ alive = Nodes
    /\ membership \in [Groups -> SUBSET Nodes]
    /\ registrations = [g \in Groups |-> [n \in Names |-> NULL]]
    /\ connections = {}

SameGroup(a, b) ==
    \E g \in Groups :
        /\ a \in membership[g]
        /\ b \in membership[g]

AddNode(g, n) ==
    /\ n \in alive
    /\ membership' =
         [membership EXCEPT ![g] = @ \cup {n}]
    /\ UNCHANGED <<alive, registrations, connections>>

RemoveNode(g, n) ==
    /\ membership' =
         [membership EXCEPT ![g] = @ \ {n}]
    /\ UNCHANGED <<alive, registrations, connections>>

Connect(a, b) ==
    /\ a \in alive
    /\ b \in alive
    /\ SameGroup(a, b)
    /\ connections' = connections \cup {{a,b}}
    /\ UNCHANGED <<alive, membership, registrations>>

Register(g, name, pid) ==
    /\ registrations[g][name] = NULL
    /\ registrations' =
         [registrations EXCEPT ![g][name] = pid]
    /\ UNCHANGED <<alive, membership, connections>>

Crash(n) ==
    /\ n \in alive
    /\ alive' = alive \ {n}
    /\ connections' =
         {e \in connections : n \notin e}
    /\ UNCHANGED <<membership, registrations>>

Next ==
    \/ \E g \in Groups, n \in Nodes : AddNode(g,n)
    \/ \E g \in Groups, n \in Nodes : RemoveNode(g,n)
    \/ \E a,b \in Nodes : Connect(a,b)
    \/ \E n \in Nodes : Crash(n)

NoIllegalConnection ==
    \A e \in connections :
        \E a,b \in e : SameGroup(a,b)

GroupNameIsolation ==
    \A g1,g2 \in Groups :
      g1 # g2 =>
        registrations[g1] # registrations[g2]
        \/ registrations[g1] = registrations[g2]

=================================================================
```

That is only the start. The production model should separate **desired membership**, **locally observed membership**, and **connection state** so that asynchronous convergence can be represented instead of assuming atomic global transitions.

The property checklist should contain at least:

**Connection safety.** A connection must not arise *solely by transitive distribution propagation* between unrelated groups. Direct application-requested connections may need a separately modeled policy.

**Intra-group convergence.** If membership stops changing and communication remains possible, members eventually agree on group membership.

**Namespace isolation.** Registering `worker_pool` in `local_ai` does not alter `worker_pool` in `external_ai`.

**Registration uniqueness.** A group cannot stabilize with conflicting live owners for a name under the intended semantics.

**Removal safety.** Once removal has converged, a removed node no longer participates in that group's namespace.

**Crash isolation.** Failure of a node does not corrupt unrelated group state.

**Recovery.** Under `-rsconfig` semantics, a restarted node eventually regains the membership represented by its persisted state, subject to whatever conflict rules the reference defines. The historical mechanism explicitly writes s-group state when membership changes. citeturn30view3

**Duplicate group-name behavior.** The historical design did not promise globally coordinated group-name uniqueness; it instead designed predictable behavior and used UUID-like naming for automatically created groups. Preserve that behavior unless an explicit v2 spec changes it. citeturn30view3

**Idempotence.** Retried topology reconciliation must not accumulate divergent state.

**Partition healing.** When communication recovers and membership stops changing, reachable nodes converge.

**No global work amplification.** A change to group G should not require communication with every node outside G.

Finally run ordinary OTP tests. At minimum:

```bash
make
make release_tests
```

plus Kernel/stdlib/Common Test suites relevant to:

```text
net_kernel
global
global_group
distribution
node monitoring
links
monitors
application startup
TLS distribution
```

The old OTP installation documentation includes the OTP smoke/release test workflow and should remain part of the historical validation record. citeturn8search2

The acceptance matrix should look like:

| Gate | Historical 19.3 | Candidate current |
|---|---:|---:|
| Compile | required | required |
| OTP smoke tests | required | required |
| s_group API checks | required | required |
| Original QuickCheck | when licensed | n/a/reference |
| PropEr oracle replay | required | required |
| Differential traces | oracle | must match |
| TLS cluster | archival/private | required |
| 14-node historical topology | required | required |
| fault/restart tests | required | required |
| TLC safety | model | required |
| TLC liveness | model | required |
| reproducible rebuild | preferred | required |
| SBOM/provenance | archival manifest | required |

A release fails closed. **“AI says the patch looks equivalent” is never an acceptance criterion.**

## Elixir automation service, deterministic rebasing, and AI-assisted patching

I would implement the service as an Elixir umbrella project but keep the actual source-transform/build workers external and disposable.

A reasonable layout:

```text
sd_resurrector/
├── apps/
│   ├── sd_control/
│   ├── sd_sources/
│   ├── sd_patch/
│   ├── sd_builder/
│   ├── sd_verify/
│   ├── sd_publish/
│   └── sd_web/
├── patches/
├── models/
├── test/
├── docker/
├── manifests/
├── vendor/
└── .github/workflows/
```

The supervision tree:

```elixir
defmodule SdControl.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      SdControl.ManifestStore,
      SdSources.OtpWatcher,
      SdSources.ReferenceMirror,
      {Registry, keys: :unique, name: SdControl.JobRegistry},
      {DynamicSupervisor,
       strategy: :one_for_one,
       name: SdControl.BuildSupervisor},
      SdControl.Scheduler,
      SdPublish.Registry,
      SdWeb.Endpoint
    ]

    Supervisor.start_link(
      children,
      strategy: :one_for_one,
      name: SdControl.Supervisor
    )
  end
end
```

`OtpWatcher` should behave like Bob conceptually. Bob checks for new OTP/Elixir releases every fifteen minutes. citeturn24search0 Your watcher can simply maintain a local bare mirror:

```elixir
defmodule SdSources.OtpWatcher do
  use GenServer

  @poll_interval :timer.minutes(15)

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def init(opts) do
    send(self(), :poll)
    {:ok, %{repo: Keyword.fetch!(opts, :repo)}}
  end

  def handle_info(:poll, state) do
    result =
      System.cmd(
        "git",
        ["-C", state.repo, "fetch", "--tags", "--prune", "origin"],
        stderr_to_stdout: true,
        env: [{"LC_ALL", "C"}]
      )

    SdSources.ReleaseScanner.handle_fetch(result, state.repo)

    Process.send_after(self(), :poll, @poll_interval)
    {:noreply, state}
  end
end
```

Never construct shell strings from a tag name:

```elixir
# GOOD
System.cmd("git", ["checkout", "--detach", sha])

# BAD
System.cmd("sh", ["-c", "git checkout #{untrusted_ref}"])
```

Each build gets a deterministic job identity:

```text
SHA256(
    upstream_commit_sha
 || patchset_sha256
 || transform_policy_sha256
 || builder_image_digest
 || test_suite_sha256
)
```

Store a manifest like:

```json
{
  "job_id": "sha256:...",
  "upstream": {
    "tag": "OTP-29.1.2",
    "sha": "..."
  },
  "sd_patchset": "s_group-v1.4.0",
  "builder": "ghcr.io/...@sha256:...",
  "policy": "2026-10-16.1",
  "status": "validating"
}
```

The deterministic port algorithm should be:

```text
clean upstream tag
      ↓
known textual patch stack
      ↓
known syntax-aware transforms
      ↓
API-shape assertions
      ↓
compiler
```

not:

```text
new OTP → ask LLM to port entire project
```

Maintain small patches:

```text
0001-kernel-register-s_group-config.patch
0002-net_kernel-group-connectivity.patch
0003-global-group-aware-search.patch
0004-add-s_group-module.patch
0005-kernel-app-register-s_group.patch
```

rather than one giant diff.

Each release begins from a new upstream checkout:

```bash
git clone --reference-if-able /mirrors/otp.git work/OTP-29.1.2
cd work/OTP-29.1.2

git checkout --detach "$UPSTREAM_SHA"

for patch in ../../patches/current/*.patch; do
  git apply --3way "$patch"
done
```

I would call this **reconstruction**, not rebasing. You are deterministically reconstructing:

```text
SD(tag) = upstream(tag) + patchset(tag)
```

from immutable inputs. That is easier to audit than preserving years of rewritten Git history.

Use Erlang's own syntax tools for transformations whenever the change is syntactic. For example, a migration that changes a function form can parse with `epp`/`erl_syntax`, locate the desired function and rewrite it. Keep text patching for small stable contexts.

Only invoke the AI patcher when one of these occurs:

```text
git patch conflict
compile failure in approved SD paths
semantic structural assertion failure
candidate-specific test failure that is plausibly compatibility-related
```

The AI receives:

```text
upstream OLD version of changed module
SD OLD version
upstream NEW version
current failed candidate
compiler/test diagnostics
SD semantic requirements
permitted paths
```

It does **not** receive permission to redesign the system.

Use an output schema such as:

```json
{
  "analysis_summary": "...",
  "files": [
    {
      "path": "lib/kernel/src/net_kernel.erl",
      "patch": "..."
    }
  ],
  "claimed_preserved_properties": [
    "non-transitive inter-group discovery",
    "s_group membership semantics"
  ],
  "uncertainties": [
    "upstream connection-state representation changed"
  ]
}
```

The sandbox policy should enforce:

```yaml
writable:
  - lib/kernel/src/global.erl
  - lib/kernel/src/global_search.erl
  - lib/kernel/src/kernel.erl
  - lib/kernel/src/net_kernel.erl
  - lib/kernel/src/s_group.erl
  - lib/kernel/src/kernel.app.src

read_only:
  - test/**
  - models/**
  - manifests/**
  - .github/**
  - release/**
  - security/**
  - patches/reference/**

network: false
secrets: none
max_changed_lines: 500
```

A patch touching more than your configured threshold should require review regardless of tests.

“Temperature zero” is not reproducibility. Instead record:

```text
model provider
model identifier/version
prompt-template SHA
input-file SHAs
tool definitions
generation parameters
raw response SHA
normalized patch SHA
```

Cache by all those inputs.

For especially sensitive transitions, run the AI twice in independent clean sandboxes. If the normalized patches differ materially, automatically mark:

```text
requires_human_design_review
```

The crucial rule is:

> **An AI-generated production-code patch may never modify the oracle that approves it.**

If upstream semantics legitimately require changing a test or TLA+ model, that is a distinct PR reviewed first or separately.

The build state machine could be:

```elixir
defmodule SdControl.BuildState do
  @type t ::
          :discovered
          | :archived
          | :patched
          | :ai_patch_proposed
          | :compiled
          | :otp_tested
          | :differential_tested
          | :pbt_tested
          | :model_checked
          | :reproducible
          | :approved
          | :published
          | :failed
end
```

The *current* first port should be manual:

```text
19.3 oracle
    ↓
understand exact semantics
    ↓
OTP 29.1.2 source
    ↓
manual minimal implementation
    ↓
prove equivalence
    ↓
call that patchset sd-v1
```

Only then train the maintenance workflow on artificial upgrades:

```text
29.1.2 → next patch
29.1.x → next patch
29.x → 30.0 RC
```

That gives you actual examples of changes the automation must manage.

GitHub Actions should provide public auditability while your home lab supplies the compute. GitHub supports self-hosted runners on physical, VM and cloud machines, and recommends ephemeral runner models where appropriate. citeturn23search0turn23search6

A build workflow:

```yaml
name: SD Erlang candidate

on:
  workflow_dispatch:
    inputs:
      otp_ref:
        description: OTP tag
        required: true

permissions:
  contents: read
  packages: write
  id-token: write
  attestations: write

jobs:
  build-test:
    runs-on: [self-hosted, linux, x64, sd-builder]
    timeout-minutes: 180

    steps:
      - uses: actions/checkout@v4

      - name: Materialize candidate
        run: |
          ./bin/sd-build materialize "${{ inputs.otp_ref }}"

      - name: Build
        run: |
          ./bin/sd-build compile "${{ inputs.otp_ref }}"

      - name: OTP regression tests
        run: |
          ./bin/sd-test otp "${{ inputs.otp_ref }}"

      - name: Differential oracle tests
        run: |
          ./bin/sd-test differential "${{ inputs.otp_ref }}"

      - name: PropEr
        run: |
          ./bin/sd-test proper "${{ inputs.otp_ref }}"

      - name: TLA+
        run: |
          ./bin/sd-test tla

      - name: Reproducibility check
        run: |
          ./bin/sd-build reproducibility "${{ inputs.otp_ref }}"
```

In the real repository, pin Actions to full commit SHAs rather than floating major tags after initial setup.

For home infrastructure, I would use:

```text
Host A:
    control-plane Elixir app
    Git mirrors
    manifests
    artifact metadata

Host B:
    ephemeral x86_64 build VMs/containers
    historical builds

Host C if available:
    arm64 builder
    or second x86 fault-test host

NAS/object storage:
    source bundles
    build cache
    candidate artifacts
    PBT histories
```

Do not expose a general self-hosted runner attached to your home LAN to arbitrary pull-request code. Run trusted branches only, isolate the runner on its own VLAN/VM, and give individual jobs no persistent credentials.

For short-lived cloud workers, DigitalOcean is operationally simple and now bills many Droplet uses on fine-grained consumption terms; AWS Spot is specifically intended for interruptible workloads and can provide substantial discounts relative to on-demand capacity. citeturn22search0turn22search5 Builds, fuzz/PBT jobs and scale tests are excellent interruptible workloads because they can be resumed from immutable manifests.

A useful split is:

```text
home:
    every OTP poll
    compilation
    normal tests
    14-node local tests
    package/image generation

cloud:
    weekly 100+ node topology tests
    cross-host packet-loss tests
    arm64 when unavailable locally
    release-candidate soak testing
```

Do not rent 100 VMs to test the PBT state machine every day. Fourteen lightweight Erlang nodes fit comfortably in containers or network namespaces. Rent real distributed infrastructure only to test things that one kernel/network stack cannot faithfully simulate.

## Packaging, supply-chain security, and observability

Bob should be treated as your UX model rather than something to fork blindly. Bob polls Erlang and Elixir releases every fifteen minutes, creates architecture/OS-specific OTP archives, builds Erlang and Elixir Docker images, publishes amd64/arm64 variants and promises immutable published tags. citeturn24search0turn24search1

Adopt a parallel naming scheme:

```text
SD version:
    sd.1
    sd.2

OCI:
    ghcr.io/sd-erlang/erlang:29.1.2-sd.1-ubuntu-24.04
    ghcr.io/sd-erlang/erlang:29.1.2-sd.1-debian-trixie

Elixir:
    ghcr.io/sd-erlang/elixir:
      1.20.4-erlang-29.1.2-sd.1-debian-trixie

binary:
    OTP-29.1.2-sd.1.tar.gz
```

Never repoint:

```text
29.1.2-sd.1
```

to a new digest.

Convenience aliases such as:

```text
29-sd
29.1-sd
latest
```

may move, but they must not be the artifacts used by reproducible deployments.

Produce a manifest alongside every build:

```json
{
  "release": "OTP-29.1.2-sd.1",
  "otp_tag": "OTP-29.1.2",
  "otp_sha": "...",
  "sd_patchset_sha256": "...",
  "builder_image": "sha256:...",
  "source_date_epoch": 1791964800,
  "architecture": "amd64",
  "tests": {
    "otp": "pass",
    "differential": "pass",
    "proper": "pass",
    "tla": "pass"
  }
}
```

For tar reproducibility:

```bash
export SOURCE_DATE_EPOCH="$(git show -s --format=%ct "$UPSTREAM_SHA")"

tar \
  --sort=name \
  --mtime="@${SOURCE_DATE_EPOCH}" \
  --owner=0 \
  --group=0 \
  --numeric-owner \
  -cf otp.tar "$PREFIX"

gzip -n otp.tar
sha256sum otp.tar.gz
```

Perform two clean builds:

```text
builder instance A
builder instance B
         │
         ▼
compare SHA-256
         │
      differs?
      /     \
    yes      no
     │        │
 diffoscope   publishable
 investigation
```

Not every legacy OTP build will be bit-for-bit reproducible immediately. Treat that as a measurable engineering task rather than silently claiming reproducibility.

Publish at least:

```text
binary archive
OCI image
source patch stack
source bundle/hash
SHA-256 sums
CycloneDX or SPDX SBOM
build manifest
test report
provenance attestation
signature
```

For signing, Sigstore's Cosign supports signing OCI images and arbitrary blobs as well as in-toto-style attestations. citeturn23search13turn24search7 GitHub Actions can additionally produce artifact attestations using OIDC-backed provenance; GitHub documents the `attestations: write` and `id-token: write` permissions and `gh attestation verify`. citeturn23search5turn23search11

A release job can therefore do:

```bash
cosign sign \
  ghcr.io/sd-erlang/erlang@sha256:THE_DIGEST

cosign verify \
  --certificate-identity-regexp \
  'https://github.com/sd-erlang/.*' \
  ghcr.io/sd-erlang/erlang@sha256:THE_DIGEST
```

and GitHub provenance in parallel.

The long-term package sequence should be:

```text
MVP:
    tar.gz
    OCI image

next:
    Debian .deb

later:
    RPM
    language-layer images
```

Do not spend the first month reproducing every distribution package format. Docker/OCI plus an OTP installation archive provide enough surface to validate whether the runtime is worth maintaining.

Elixir should be the first downstream compatibility consumer. Bob already models Elixir images as a layer over particular Erlang releases, which is exactly the composition you want. citeturn24search0turn24search3

Conceptually:

```dockerfile
ARG SD_ERLANG_IMAGE
FROM ${SD_ERLANG_IMAGE} AS erlang

# Add the normal Elixir 1.20.4 compiler/runtime layer,
# but do not replace ERTS/OTP with stock Erlang.
```

Then execute:

```elixir
IO.inspect(System.otp_release())
IO.inspect(Node.self())

# Direct Erlang call from Elixir:
:s_group.own_s_groups()
```

After Elixir, add smoke suites for Gleam and any other target language. The compatibility criterion is:

```text
can compile
can launch on SD ERTS
can use ordinary distributed processes
can invoke s_group where needed
ordinary ecosystem libraries still pass
```

Do not fork those languages unless actual evidence says it is necessary.

AtomVM should be treated as a **future interop research track**, not a downstream SD build. AtomVM is its own small Erlang VM implementation, and recent releases have added Erlang Distribution so AtomVM devices can connect to BEAM or other AtomVM nodes. citeturn25search10turn25search24turn25search39 Your modifications to OTP Kernel do not magically modify AtomVM. Supporting `s_group` semantics on an ESP32-class AtomVM node would require either compatible AtomVM runtime/library work or treating the device as an ordinary distribution endpoint behind an SD-aware gateway.

Observability should be designed into the validation service from day one.

The **modern Elixir control plane** can use OpenTelemetry. Erlang/Elixir OpenTelemetry provides tracing support and OTLP exporters; the current Hex exporter release line is actively maintained. citeturn21search0turn21search1turn26search10

Instrument a build with spans like:

```text
otp.release.detect
otp.source.fetch
sd.patch.apply
sd.ai.patch
otp.compile
otp.common_test
sd.differential
sd.proper
sd.tlc
image.build
artifact.sign
artifact.publish
```

Include attributes:

```text
otp.version
otp.commit
sd.patchset
architecture
builder.digest
ai.used
ai.model
proper.seed
tlc.states_generated
test.nodes
image.digest
```

The historical OTP 17/19 runtimes should **not** be burdened with a current OpenTelemetry library stack. Export their observations through the harness:

```text
historical node
      │
  simple Erlang probe
      │ ETF/TCP/file
      ▼
modern harness
      │
 OpenTelemetry
```

`seq_trace` is especially valuable here because Erlang's sequential trace token follows message activity across local and distributed process interactions. Modern OTP documentation describes the token being propagated through messages and the per-node system tracer, after which distributed traces can be correlated. citeturn21search7

For a semantic test:

```erlang
seq_trace:set_token(label, JobId),
seq_trace:set_token(send, true),
seq_trace:set_token('receive', true),

s_group:send(
    'gpu1@sd.local',
    local_ai,
    worker_pool,
    {run, JobId}
).
```

Capture on each node, then merge by label in the harness. That gives you concrete evidence such as:

```text
gateway → gpu1
```

without accidentally observing:

```text
gateway → core → unrelated_node
```

for a topology where that path should not arise.

Also instrument:

```text
nodes known by node
distribution connections
s_groups per node
membership per group
registered names
message queue length
distribution port busy time where available
disconnect/reconnect count
PBT convergence latency
```

WombatOAM is worth keeping as an **optional independent observer**. Erlang Solutions currently describes WombatOAM as able to inspect BEAM processes, queues, process state and topology; it can discover a topology from a node/cookie relationship. citeturn26search6 Historically, the RELEASE work explicitly involved Erlang Solutions and considered interaction between Wombat's deployment/recovery tooling and reliable SD Erlang. citeturn30view3

That makes it an unusually relevant external validation tool, but because it is commercial/proprietary it should never be required to build or certify the OSS release.

## Ecosystem positioning and the actual reason to choose SD Erlang

The resurrection project should avoid marketing SD Erlang as “the only way Erlang can scale.” The ecosystem spent the intervening decade solving different parts of this problem in other ways, some of them extremely good.

The useful question is narrower:

> **What capability does native s-group topology provide that is awkward to reproduce while preserving ordinary Erlang distribution semantics?**

**SD Erlang.** Its distinctive superpower is **topology-aware native Erlang distribution**. Processes remain ordinary BEAM processes, PIDs remain PIDs, native distribution remains the substrate, while nodes can participate in overlapping connectivity/name domains rather than treating one enormous connected system as homogeneous. Glasgow describes SD Erlang as a small conservative extension and makes group-scoped registration plus restricted transitive connectivity central to the design. citeturn30view2turn30view3 Choose it if native Erlang semantics and low migration cost are important *and* your node communication graph is naturally sparse/overlapping. The cost is owning a non-mainline OTP patch unless it eventually gets upstreamed.

**Partisan.** This is the strongest modern control case. It is an alternative Erlang distribution layer with pluggable topologies; current Partisan supports modern OTP lines and includes full-mesh, peer-to-peer/HyParView-like, client/server and static approaches. It can use multiple channels, directly addressing the head-of-line/single-channel concern you raised earlier. citeturn13search0 In desired outcome, Partisan and SD Erlang can become **extremely similar**: both seek a topology that does not equal one enormous conventional Disterl mesh. Their crucial difference is where the abstraction boundary lives. SD Erlang modifies native distribution and seeks to preserve ordinary Erlang idioms; Partisan creates a replaceable application distribution layer. Your reference application should be implemented both ways.

**Lasp.** Lasp is better thought of as a research programming model for coordination-free, eventually consistent distributed computation than as “another Erlang distribution.” Its work drove/used Partisan because the CRDT-heavy application model needed distribution that scaled beyond stock full mesh. citeturn13search1 Its superpower is reasoning about convergent distributed state. SD Erlang's superpower is runtime communication topology. They can coexist conceptually.

**`pg`.** Current OTP `pg` supplies distributed named process groups and scopes. Scopes allow separate membership universes and can reduce process-group membership propagation, but they do **not** by themselves replace Erlang Distribution's physical connection semantics. citeturn16search0 Use `pg` when the real need is service/process discovery. Use SD Erlang only when the node-level distribution topology itself is the scaling issue.

**`group`.** OTP's `group` module is principally an I/O group/shell group-leader implementation, not a clustering counterpart to `pg` or `s_group`. It belongs in this checklist mainly to prevent a naming collision from becoming an architectural comparison. citeturn12search4

**`spg`.** This is historically very important. Glasgow's impact documentation explicitly says WhatsApp reimplemented the SD Erlang Scalable Groups concept as **Scalable Process Groups** and points to `https://github.com/max-au/spg`. citeturn11search1 `spg` is much closer to scalable service/process discovery than to replacing the entire distribution transport. It is therefore evidence both *for* SD Erlang's underlying idea and *against* the claim that an OTP fork is the only way to obtain value from it.

**Riak Core.** Riak Core's superpower is **ownership topology**: consistent-hash ring, virtual nodes, gossip, handoff and movement of partition responsibility as physical membership changes. Its documentation describes each node holding the ring, vnodes owning partitions and handoff transferring responsibility. citeturn25search0turn25search1 It is orthogonal to SD Erlang's **communication topology**. This is not merely a modern reinterpretation: the RELEASE report explicitly proposed s-groups derived from Riak preference-list neighbors. citeturn30view3 A future `riak_core + s_group` experiment is one of the strongest technical demonstrations you could build.

**PlumDB.** PlumDB is a replicated eventually consistent data/metadata substrate descended from Riak Core ideas and built around Partisan/epidemic dissemination rather than a replacement for native process semantics. citeturn15search0 Use it when the missing primitive is convergent replicated metadata. SD Erlang does not solve that problem.

**Giocci.** Giocci's superpower is remote **compute placement across heterogeneous edge/cloud resources**. Its current architecture uses client/relay/engine components and Zenoh communication. citeturn13search3turn13search4 That makes it superficially very similar to the *placement* ambitions of SD Erlang, but it lives a layer above/different from native Disterl. Prefer Giocci when you want “execute this computation somewhere appropriate across edge/MEC/cloud” rather than “make my Erlang distribution topology sparse while preserving Erlang runtime semantics.”

**Zenoh.** Zenoh unifies pub/sub, query/reply, storage and computation concepts under a key-expression-oriented networking model and supports peer-to-peer, brokered and hybrid topologies. citeturn25search16turn25search20 For unreliable, heterogeneous WAN/edge environments, that is a stronger abstraction than pretending the world is one Erlang cluster. If the network boundary itself is part of your public protocol, I would usually pick Zenoh/MQTT/Kafka/etc. before exposing native Disterl. SD Erlang is strongest **inside a trusted Erlang system**, not as an Internet-wide messaging protocol.

**Bondy Connect.** Bondy Connect is a WAMP/service/event-mesh system whose architecture uses Partisan and distributed/CRDT techniques; its design explicitly benefits from separate topology and channel concepts. citeturn14search3turn14search6 Use Bondy when the application really wants authenticated RPC/pub-sub/service-mesh semantics. SD Erlang is lower level.

**The new Bondy language.** Alejandro Ramallo's newly announced Bondy language is a much higher-level proposition: statically typed, functional/relational/rule-oriented and intended to compile to BEAM, with an emphasis on declarative application construction. It was publicly announced in October 2026, so it is still early compared with OTP or Partisan. citeturn14search0 Its “superpower,” if the design matures, is reducing *application specification* rather than altering node connectivity. A Bondy program could theoretically run on a topology substrate; it is not inherently a replacement for one.

**AtomVM.** AtomVM now makes the comparison more interesting because it supports Erlang Distribution on microcontrollers, including network-capable ESP32-class hardware. citeturn25search10turn25search39 SD Erlang does not automatically extend to it, but this creates a future research question: can an SD-aware gateway or compatible lightweight group implementation allow thousands of embedded Erlang nodes without constructing absurd all-peer relationships?

The WhatsApp evidence is particularly instructive. A WhatsApp engineer's 2018 talk was explicitly titled **“Scaling Erlang cluster to 10,000 nodes”**, describing growth from tens/hundreds toward thousands and 10,000 machines, and another 2019 talk describes a production system spanning more than 10,000 nodes. citeturn29search3 Glasgow separately records WhatsApp's `spg` work as a reimplementation of the scalable-groups idea. citeturn11search1

That does **not** justify claiming WhatsApp ran SD Erlang. It demonstrates something more useful:

> At sufficiently large Erlang scale, sophisticated teams independently start introducing bounded scopes, scalable process groups, topology-aware discovery, specialized routing or other mechanisms that weaken the assumption that every process/node relationship should be globally uniform.

Your project could make one such technique available to organizations that are not WhatsApp.

I would therefore define the “choose SD Erlang” rule this way:

```text
Do you merely need service discovery?
    → pg / libcluster

Do you need partition ownership and data handoff?
    → Riak Core

Do you need convergent replicated state?
    → PlumDB / CRDT approaches / Lasp lineage

Do you need WAN pub/sub/query?
    → Zenoh / Kafka / MQTT / etc.

Do you need WAMP/service mesh?
    → Bondy Connect

Do you need heterogeneous remote computation?
    → Giocci

Do you want a different Erlang transport/topology
and can adapt application communication?
    → Partisan

Do you specifically want to retain native Erlang
distribution/process semantics while bounding
the topology and namespaces of a very large
multi-role Erlang system?
    → that is the strongest case for SD Erlang
```

And this gives you the most important empirical experiment in the whole project:

```text
same application
same topology
same workload
same failure schedule

Implementation A: stock OTP + pg/libcluster
Implementation B: Partisan
Implementation C: resurrected SD Erlang
```

Measure:

```text
application LOC changed
number of distribution-specific abstractions
connection count
memory/node
control-plane message volume
failure convergence
throughput
p50/p95/p99 message latency
head-of-line effects
operational complexity
developer mental-model changes
```

If Partisan wins every dimension, the resurrection effort has still produced valuable evidence and historical preservation.

If SD Erlang preserves substantially more ordinary OTP code while approaching Partisan's topology scalability, you have found its modern reason to exist.

## Delivery roadmap, resource requirements, funding, and governance

I would not start with “automatically port SD Erlang to every new OTP.” That skips the knowledge-generating part.

A realistic sequence is:

| Milestone | Output | Estimated experienced-engineer effort |
|---|---|---:|
| Historical preservation | SHA-pinned 17.4/19.3 source bundles and builders | 1–2 weeks |
| Reference runtime | reproducible-ish 19.3 cluster + demo | 1–2 weeks |
| Semantic extraction | minimal six-file patch + behavior inventory | 1–2 weeks |
| PBT preservation | original QC status + working PropEr model | 2–4 weeks |
| Formal model | useful TLA+/TLC model and CI checks | 2–4 weeks |
| Modern manual port | OTP 29.1.2 candidate | 4–8 weeks |
| Differential validation | reference-vs-current semantic harness | 2–4 weeks |
| Build automation | Elixir controller + self-hosted pipeline | 3–6 weeks |
| Supply chain | OCI/tar/SBOM/signing/provenance | 1–3 weeks |
| Discovery/security demo | TLS + DNS/K8s/manual discovery | 2–3 weeks |
| Partisan comparison | equivalent topology benchmark | 2–4 weeks |
| Multi-arch hardening | amd64 + arm64 | 2–4 weeks |

These are engineering estimates, not promises. There is substantial uncertainty in the modern port because the decisive question is how deeply current `net_kernel`/`global` behavior has diverged from the assumptions of the 19.3 implementation.

For one strong Erlang engineer working substantially full time, I would budget roughly **three to five months for a credible research-quality MVP** and perhaps **six to nine months before describing the modern images as something production users should depend on**.

The MVP definition should be demanding but finite:

```text
✓ historical 19.3 builds from archived source
✓ reference app works
✓ PropEr model exists
✓ TLA+ model exists
✓ OTP 29.1.2 manual port works
✓ reference/candidate differential test passes
✓ TLS distribution works
✓ static + DNS discovery works
✓ Partisan control implementation exists
✓ amd64 signed OCI image published
✓ release provenance published
```

The first MVP explicitly does **not** need:

```text
RPM
every Linux distro
Gleam/Hamler images
AtomVM s_group support
1000-node benchmark
fully autonomous AI maintenance
automatic upstream PRs
```

For a home lab, I would consider this sufficient initially:

```text
builder:
    8–16 modern CPU cores
    32 GB RAM minimum
    64 GB convenient

storage:
    500 GB SSD comfortable
    more if retaining all OCI layers/test traces

architecture:
    x86_64 first

network:
    separate lab VLAN/bridge
    ability to create several VMs/containers

optional:
    second physical machine
    ARM64 machine
```

The control service itself needs very little. OTP compilation, parallel testing, containers and retained build layers consume the resources.

A 14-node semantic test should consist of lightweight BEAM containers or namespaces, not 14 physical servers. The historical RELEASE QuickCheck test itself used 14 Erlang nodes as its validation arrangement. citeturn6view0

Real multi-machine testing enters later:

```text
3 hosts:
    physical topology behavior

10–30:
    ordinary scale testing

100:
    topology/connection-count experiments

500+:
    research benchmark

1000+:
    only after evidence justifies the expense
```

AWS Spot instances are well suited to the last categories because AWS explicitly positions Spot capacity for interruptible workloads at potentially large discounts. citeturn22search5turn22search6 DigitalOcean is simpler operationally for modest temporary fleets. I would choose cloud based on benchmark convenience rather than architect the service around either provider.

The controller should use an interface such as:

```elixir
defmodule SdBuilder.Executor do
  @callback run(
              job :: map(),
              resources :: map()
            ) ::
              {:ok, result :: map()}
              | {:error, term()}
end
```

Implement:

```text
LocalDocker
LocalVM
GitHubSelfHosted
DigitalOcean
AWS
```

later without changing the semantic pipeline.

Funding is plausible precisely because this project has several constituencies:

**BEAM infrastructure users** may value a maintained experimental large-cluster runtime even without using it immediately.

**Erlang consultancies/vendors** have an interest in demonstrating that the platform remains technically credible at unusual scale.

**IoT/telecom/messaging organizations** have direct business cases for hierarchical or sparse cluster relationships.

**Academic distributed-systems groups** may value the rare combination of a historical formal semantics, operational production runtime and modern automated program transformation.

**Tooling/AI sponsors** may find “AI-maintained runtime fork whose correctness is independently checked by executable semantics/PBT/model checking” more compelling than another ordinary coding-agent demonstration.

Potential outreach targets include the Erlang/Elixir ecosystem's commercial vendors and large users, relevant research groups, open-source infrastructure grant programs, university-industry collaborations, GitHub Sponsors/Open Collective-style community funding, and companies whose products depend materially on BEAM scalability. Those should be treated as sponsorship candidates rather than assumptions about available funding.

I would create the project under a neutral organization rather than a personal fork:

```text
github.com/sd-erlang/
    otp-patches
    resurrector
    models
    reference-app
    benchmarks
```

Governance should distinguish three things:

```text
specification
implementation
release machinery
```

No single PR should casually rewrite all three.

Require:

```text
CODEOWNERS for Kernel patch paths
CODEOWNERS for TLA+ specs
CODEOWNERS for release/signing workflows
security policy
responsible disclosure address
documented release criteria
two-person approval for signing-policy changes
```

An AI attribution policy should record generated patches but avoid pretending authorship provenance proves correctness. The important provenance is:

```text
what inputs generated this diff?
which tests checked it?
which model version checked it?
who approved it?
what exact source produced the binary?
```

For releases, publish a human-readable record:

```markdown
OTP-29.1.2-sd.1

Upstream:
OTP-29.1.2 / <SHA>

SD patch:
s_group-v1.0 / <SHA256>

Compatibility intervention:
Manual initial port

AI-generated production changes:
None

Validation:
- OTP Kernel suite: PASS
- Differential 19.3 oracle: PASS
- PropEr: 100,000 sequences PASS
- TLA+ invariants: PASS
- TLS 14-node test: PASS

Architectures:
- linux/amd64

Known differences:
...
```

When an AI-assisted release eventually occurs:

```markdown
AI intervention:
yes

Model:
<recorded model ID>

Reason:
net_kernel connection-state API changed upstream

Generated paths:
lib/kernel/src/net_kernel.erl

Generated LOC:
37

Tests/specification changed in same PR:
no

Human reviewers:
...
```

That degree of transparency would make the project unusually trustworthy.

The upstreaming strategy should also be conservative. Do not begin by proposing the entire historical SD Erlang implementation to OTP.

First establish:

```text
historical semantics
      ↓
current implementation
      ↓
benchmarks
      ↓
Partisan comparison
      ↓
real users
      ↓
identify smallest generally useful primitive
```

The upstreamable thing may turn out not to be `s_group` exactly. It might be:

```text
a distribution connection-policy callback
a native topology provider
better scoped name/discovery primitives
connection-transitivity controls
multiple distribution channels
a supported hook sufficient for an external s_group library
```

If OTP eventually exposes the right hooks, your maintained fork could shrink until the entire resurrection service becomes unnecessary. **That would be success, not project failure.**

There is precedent for the ecosystem evolving pieces of these ideas independently. Modern `pg` provides scalable scoped process groups; Partisan externalizes distribution topology; WhatsApp built SPG at enormous scale; Riak Core made ownership topology explicit; Bondy/PlumDB build higher-level distributed semantics on Partisan; Giocci/Zenoh treat heterogeneous resource/network topology as fundamental; and AtomVM has now carried Erlang Distribution down into microcontroller deployments. citeturn16search0turn13search0turn11search1turn25search1turn15search0turn13search4turn25search16turn25search10

That means the strongest version of this project is **not nostalgic preservation**. It is an experiment in whether a missing abstraction can still be recovered:

> **Can topology become a first-class property of Erlang distribution without forcing Erlang applications to stop feeling like Erlang applications?**

The architecture above lets you answer that question rigorously.

It preserves the original implementation as the golden reference, turns the old QuickCheck work into an open PropEr regression oracle, gives the protocol an executable TLA+ specification, measures modern SD Erlang directly against Partisan rather than hand-waving about superiority, and makes future OTP maintenance largely mechanical—with AI assisting only where upstream structural change defeats deterministic transforms.

The resulting service would essentially be **Bob the Builder plus semantic preservation**:

```text
                  Bob
                   │
        detect → build → package
                   │
                   ▼
           immutable artifact


            SD Resurrector
                   │
                 detect
                   │
              reconstruct
                   │
          compatibility patch
                   │
          prove old semantics
             /     |      \
          PBT   oracle    TLA+
             \     |      /
                   │
                build
                   │
             reproduce
                   │
                 sign
                   │
                publish
```

That is the implementation direction I would use for a serious resurrection effort, with **SD Erlang/OTP 19.3 as the golden executable specification, OTP 29.1.2 as the first modern manual port, Partisan as the mandatory contemporary control, and automation beginning only after those three points are understood.** citeturn30view2turn30view3turn27search0turn13search0