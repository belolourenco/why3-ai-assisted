# Why3 with AI-assisted Coq proof search

This fork extends [Why3](https://gitlab.inria.fr/why3/why3) with an experimental way to
discharge verification conditions using an AI agent. For every usable Coq
installation detected by Why3, an additional prover is made available:

```text
Coq X
Coq X (AI-assisted)
```

The ordinary Coq integration is unchanged. When the AI-assisted alternative is
selected, a Codex agent attempts to complete the Coq proof and uses Coq for
feedback. Why3 then validates the candidate independently before accepting it,
saves the accepted proof in the normal session, and replays saved proofs without
contacting the model.

This is a research prototype for evaluating the feasibility of AI-assisted
verification. It is not an official Why3 feature or a safety-certified product.

## What this fork adds

- **Version-matched Coq companions.** `why3 config detect` derives an
  `AI-assisted` companion from each compatible Coq configuration instead of
  assuming a particular Coq version or executable.
- **IDE and command-line integration.** Proof generation can be requested from
  the Why3 IDE or with `why3 prove -P coq-agent`.
- **Agent-guided proof search.** Codex edits a generated Coq script and can run
  bounded Coq checks for feedback. Model, reasoning effort, elapsed-time budget,
  and retry count are configurable through named profiles.
- **A separate acceptance boundary.** The generated VC is protected by Why3;
  incomplete proofs, unsupported context changes, stale results, and unsafe
  proof-ending commands are rejected before a proof is published.
- **Persistent and replayable proofs.** Accepted `.v` scripts are saved and can
  be inspected, edited, or checked later without Codex, its login, or the agent
  configuration.
- **Native Why3 configuration.** Agent and profile settings live in
  `[coq_agent]` and `[coq_agent_profile NAME]` sections of the normal Why3
  configuration. The earlier JSON configuration format is not supported.
- **Operational diagnostics.** Agent progress is reported through prover output,
  accepted proofs receive a non-secret provenance sidecar, and failed workspaces
  can be retained for investigation.

## How it works

An explicit AI-assisted proof attempt follows this sequence:

1. Why3 generates the current verification condition as a Coq task.
2. Codex proposes or repairs the proof script in an isolated workspace.
3. Coq feedback is made available to the agent within the configured limits.
4. Why3 checks the resulting script against the current VC using the detected
   original Coq installation and the fork's additional acceptance checks.
5. Only the exact script that passed validation is published to the session.

The model is used to search for a proof; it does not decide whether the VC is
valid. In particular, an agent response, a plausible explanation, or a
successful process exit is not sufficient. Scripts using incomplete proof
mechanisms such as `Admitted` or `Abort`, and unsupported commands that alter the
generated context, are rejected.

Replaying a saved proof is deliberately different from generating one. Replay
regenerates the current VC and checks the existing script, but it never asks the
agent to repair a failed proof. Repair requires another explicit selection of
the AI-assisted prover.

## Requirements

The current implementation requires:

- a Unix-like host;
- a Coq installation supported and detected by Why3;
- a compatible Codex CLI (the prototype has been exercised with version
  0.163.0 on Linux); and
- either a Codex **Sign in with ChatGPT** session or explicit API-key
  authentication through an environment variable.

The Coq installation must expose the matching tools required by validation.
See [INSTALL.md](INSTALL.md) for the general Why3 build instructions and
[the interactive-prover documentation](doc/itp.rst) for the detailed supported
environment.

## Quick start

### 1. Detect Coq

Build or install Why3, then refresh the prover configuration:

```sh
why3 config detect
why3 config list-provers
```

A compatible installation should produce entries similar to:

```text
Coq 8.20.1
Coq 8.20.1 (AI-assisted)
```

The `coq` shortcut continues to select ordinary Coq. The `coq-agent` shortcut
selects its AI-assisted companion. AI-assisted provers are not included in
automatically generated proof strategies, so unrelated strategy runs do not
start model calls.

### 2. Authenticate Codex

The default authentication mode reuses a Codex ChatGPT login:

```sh
codex login
codex login status
```

Why3 does not open an authentication prompt, inspect the login cache, or alter
the Codex login.

### 3. Configure the agent

Add the following to the normal Why3 configuration (`~/.why3.conf` for an
installed Why3, or the selected `why3.conf` in a local checkout):

```ini
[coq_agent]
auth = "chatgpt"
executable = "codex"
default_profile = "proof"

[coq_agent_profile proof]
model = "YOUR_MODEL_ID"
reasoning_effort = "high"
wall_time_seconds = 600
max_generation_attempts = 2
```

Replace `YOUR_MODEL_ID` with a model available to the authenticated account.
The fully commented [example configuration](share/coqagent.conf.example)
documents isolation, checking, concurrency, logging, and artifact-retention
settings. Several named profiles may be defined to use different models or
budgets.

Validate and display the effective settings without starting Codex:

```sh
why3 config show-coq-agent
why3 config show-coq-agent --coq-agent-profile=proof
```

For optional API-key authentication, refer to an environment variable; never
put the key itself in the Why3 configuration:

```ini
[coq_agent]
auth = "api_key"
api_key_env = "OPENAI_API_KEY"
```

There is no automatic fallback between authentication modes or models.

## Using the Why3 IDE

Open a WhyML file as usual:

```sh
why3 ide examples/kmp.mlw
```

Select an open verification condition and choose `Coq X (AI-assisted)` from
the prover menu. The prover-output pane reports generation, checking, elapsed
time, relevant file paths, and the final result. If a saved proof is already
valid, it is reused without a model call.

The ordinary `Coq X` entry remains available for manually edited interactive
proofs. Saved AI-generated scripts also remain ordinary Coq source files and may
be inspected or edited.

## Using the command line

Generate proofs with the AI-assisted companion:

```sh
why3 prove -P coq-agent input.mlw
```

Accepted scripts are stored in `input_coq_agent/` by default. Select another
directory or profile when needed:

```sh
why3 prove -P coq-agent \
  --coq-agent-output=proofs \
  --coq-agent-profile=proof \
  input.mlw
```

Check the saved scripts without starting Codex:

```sh
why3 prove -P coq-agent --coq-agent-check input.mlw
```

Offline checking does not require the Codex executable, login, or agent
configuration. As with other Why3 provers, `-o` only writes a prover task; it
does not invoke the agent.

## Saved proofs and diagnostics

Each accepted proof consists of a `.v` script and a `.coqagent.json` sidecar.
The sidecar records non-secret provenance such as the Coq and model versions,
selected profile, elapsed and checking times, invocation count, and any numerical
usage events reported by Codex. It is informational and is not required to
replay the proof.

Failed workspaces are retained by default and their paths are printed in prover
output. `retain_failed_attempts` and `retention_days` control that behavior.
Expired workspaces are removed when a later generation request starts; there is
no background cleanup service. Successful temporary workspaces are removed
after their accepted proof has been published.

Set `log_level = "debug"` for detailed lifecycle information in the IDE's
prover-output pane or the command-line prover output. The log covers prover
selection, workspace and script paths, Codex invocations, validation stages,
timings, publication, cleanup, and the final Why3 result.

## Current scope and limitations

- Codex is currently the only agent backend. Supporting multiple LLM agents and
  selecting them through configuration remains future work.
- The accepted Coq command subset is intentionally conservative. It can reject
  a valid proof that relies on unsupported top-level declarations or context
  changes; helper results should currently be expressed as local proof steps.
- Model calls can fail, time out, exhaust their retry budget, or simply fail to
  find a proof. Increasing the budget does not guarantee success.
- A VC may be unprovable because the program, specification, invariant, or lemma
  is wrong. In that case, further proof search is not the useful next step: the
  failed obligation must be investigated and the relevant source corrected.
- Coq, its configured environment, and installed libraries remain trusted
  components. The additional validator narrows what an agent-generated script
  may do; it is not a proof that the validator itself is defect-free.
- The prototype currently targets Unix and direct Coq commands. Wrapper commands,
  unsupported options, or untested future Coq and Codex versions may be rejected.
- Model access has cost, latency, availability, and data-governance implications
  that must be assessed before use on a real project.

The intended workflow is therefore gradual: use automated provers first, invoke
the AI-assisted Coq companion for selected remaining VCs, and keep independently
replayable proof artifacts under review and version control.

## About upstream Why3

Why3 is a platform for deductive program verification. It provides WhyML, a
language for specification and programming, and uses external automated and
interactive theorem provers to discharge verification conditions. Why3 also
provides a standard library of logical theories and common programming data
structures, supports extraction of WhyML programs to OCaml, and is used as an
intermediate verification language by other toolchains.

- [Upstream source repository](https://gitlab.inria.fr/why3/why3)
- [Why3 documentation](https://www.why3.org/doc/)
- [Standard library](stdlib/) and [examples](examples/)

## License and copyright

Why3 is distributed under the GNU LGPL 2.1. See [LICENSE](LICENSE).

The files [src/util/extmap.ml](src/util/extmap.ml) and
[src/util/extmap.mli](src/util/extmap.mli) are derived from the OCaml 3.12
standard library and are distributed under the GNU LGPL version 2; see
[OCAML-LICENSE](OCAML-LICENSE).

The graphical interface uses icon sets with their own licenses, some of which
may forbid commercial use. See the license files under
[share/images](share/images/).
