.. _chap.itp:

Interactive Proof Assistants
============================

Using an Interactive Proof Assistant to Discharge Goals
-------------------------------------------------------

Instead of calling an automated theorem prover to discharge a goal, Why3
offers the possibility to call an interactive theorem prover instead. In
that case, the interaction is decomposed into two distinct phases:

-  Edition of a proof script for the goal, typically inside a proof
   editor provided by the external interactive theorem prover;

-  Replay of an existing proof script.

An example of such an interaction is given in the :ref:`tutorial section <sec.gui>`.

Some proof assistants offer more than one possible editor, e.g., a choice
between the use of a dedicated editor and the use of the Emacs editor
and the ProofGeneral mode. Selection of the preferred mode can be made
in :menuselection:`File --> Preferences`, under the :guilabel:`Editors` tab.

.. _sec.coq-agent:

AI-assisted Coq proofs
----------------------

Each usable Coq installation has an additional ``AI-assisted`` alternative.
For example, ``Coq 8.20.1 (AI-assisted)`` uses the executable, driver, checking
options, and support library of ``Coq 8.20.1``. No version is hardcoded.
The ordinary ``coq`` shortcut remains unchanged; ``coq-agent`` selects the
companion. Agents are excluded from generated automatic strategies.

Setup
~~~~~

Install a Codex CLI supporting non-interactive execution, strict configuration,
permission profiles, ``--ignore-user-config``, and ``--ignore-rules``. The tested
interface is Codex CLI 0.163.0 on Linux. Authenticate outside Why3 using
``codex login`` and confirm ``codex login status`` reports ChatGPT login.
Why3 never opens a login prompt, reads the login cache, or changes the login.

Agent settings belong in the normal Why3 configuration: :file:`why3.conf` for
a local checkout or :file:`~/.why3.conf` for an installed Why3. Append the sections
from :file:`coqagent.conf.example`, replacing the model placeholder with a model
available to your account. For example::

    [coq_agent]
    auth = "chatgpt"
    executable = "codex"
    default_profile = "proof"

    [coq_agent_profile proof]
    model = "YOUR_MODEL_ID"
    reasoning_effort = "high"
    wall_time_seconds = 600
    max_generation_attempts = 2

Use an absolute executable path if ``codex`` is not on ``PATH``. Directory-bearing
relative paths are relative to the configuration file containing the setting.
``--extra-config`` can override individual agent settings and profile fields.
The default ``chatgpt`` mode requires no API key. Optional API authentication uses
``auth = "api_key"`` and ``api_key_env = "OPENAI_API_KEY"``; literal keys are not
allowed in the native Why3 configuration. Codex still owns its ChatGPT login.
There is no fallback between authentication modes or models.

Both discovery and saving IDE preferences preserve the native agent sections.
These sections are the only supported configuration format: JSON configuration
files, their override flag, and the former import command are not supported.
Use ``-C``/``--config`` or ``--extra-config`` to select Why3 configuration files.
``--coq-agent-profile``
overrides per-prover ``agent_profile``, which overrides the configured default.
The common flags also apply when starting the IDE. ``why3 config show-coq-agent``
validates and prints effective settings as native sections without starting Codex.

Generation and replay
~~~~~~~~~~~~~~~~~~~~~

Explicitly select the companion to generate or repair a proof. A saved proof
that still passes validation is reused without a model call. Successful proofs
are stored at the session-relative ``proof_script`` path and may be inspected
or edited normally. Generic scheduling, proof copying and session replay only
check existing scripts; repair always requires explicit generation.

``why3 prove -P coq-agent`` uses the same service and saves proofs in
:file:`<input-without-extension>_coq_agent/`. Override this with
``--coq-agent-output``. Add ``--coq-agent-check`` for offline checking. As with
other provers, ``-o`` is output-only and never invokes the agent.

Each accepted proof has a :file:`.coqagent.json` sidecar recording the Coq/model
versions, profile, elapsed/check time, invocation count, and available numerical
token-usage events. It contains no credentials. Replay does not depend on this
sidecar, Codex installation, agent settings, or login.

Validation and isolation
~~~~~~~~~~~~~~~~~~~~~~~~

A zero Coq exit status is insufficient: both ``Admitted`` and ``Abort`` can
succeed. A separate, restricted-script gate requires the generated context and
theorem declaration to remain unchanged, apart from comments and whitespace.
Additional imports before the goal are moved inside ``Proof``, so Coq elaborates
the original VC before any agent-supplied command. The proof must end with
``Qed`` or ``Defined``, with no trailing commands. Sentence heads are restricted
to supported Ltac1 tactics, imports and scope commands. Other vernacular,
including ``Reset``, declarations, notations, ML loading and checking options,
is rejected. Helpers must be local facts proved using ``assert`` or similar
tactics, not top-level lemmas; existing scripts with global helpers need to be
migrated before agent replay.

Why3 then uses ordinary Coq regeneration and the configured original Coq
checking command on the approved standalone script. A small compiled-result
audit verifies the expected theorem exists and uses ``coqchk`` to check the
compiled proof, reject unsafe declarations and compare assumptions with the
original generated context. No module-signature mechanism, imported baseline
proof context or alternative tactic replay is used. Fresh compiled objects are
required; old objects cannot stand in for a newly checked candidate. Only the
exact checked standalone bytes are published.

Installed compiled libraries selected by the original Coq configuration remain
trusted inputs. Their dependencies are not recursively rechecked on every
attempt. Imports introducing assumptions absent from the baseline are rejected;
this deliberately conservative policy can also reject otherwise valid scripts.
The source-preservation parser is not the safety gate. The restricted command
policy deliberately rejects unsupported syntax rather than accepting arbitrary
Coq scripts. Coq, its configured environment and installed library/plugin
artifacts remain trusted inputs; this is not a formal proof of the validator.

Codex tools receive a deny-by-default filesystem profile: common runtime files
and the selected Coq libraries are readable, and only the candidate workspace
is writable. The credential file, settings file, protected validation directory,
original sources and accepted proof are not exposed as writable inputs. The CLI
itself retains its existing credential store for authentication. Shell tools do
not inherit API-key overrides. Shell networking is disabled by default, separate
from Codex's connection to OpenAI. No unattended approval prompts are permitted.
``codex.ignore_user_config`` must remain true. Project-local Codex settings and
agent-instruction directories are denied to the agent's tools. Organization
configuration must not select the older ``sandbox_mode`` or
``sandbox_workspace_write`` settings, which Codex prioritizes over permission
profiles; such installations need to be migrated to permission profiles before
using this backend. Organization-managed restrictions may further restrict it.

Limits and current scope
~~~~~~~~~~~~~~~~~~~~~~~~

Generation defaults to 600 elapsed seconds, at most two Codex invocations, and
one concurrent agent job, also bounded by Why3's prover concurrency setting.
Each independent Coq check defaults to 20 seconds and 1000 MiB. The supplied
feedback command has CPU/memory bounds; arbitrary agent tool calls are bounded
by the job deadline, not a per-edit or per-tool-call count. Offline replay uses
the fixed checking defaults and a 140-second total deadline. There is no hard
token/dollar cap; reported usage is observational.

Cancellation and timeout kill the worker process group. Failures, stale goals,
changed scripts and conflicting publications cannot replace an accepted proof;
successful replacement keeps the previous script as :file:`.bak`. Failed job
directories are reported in prover output and retained by default for seven
days. Expired finished-job directories are removed on the next generation
request. Successful directories are removed immediately. Disabling failed-job
retention also removes interrupted-job directories.

The implementation currently requires a Unix host and a direct ``coqtop``
command with matching sibling ``coqc`` and ``coqchk`` executables. It supports
the standard Why3 Coq command, ``-R``, ``-Q``, ``-I``, ``-coqlib``, ``-w``,
``-impredicative-set`` and ``-indices-matter``. Unsupported wrapper commands,
options, checker output or source-side-effect commands fail closed. Private
validation directories must not overlap a configured Coq library path.
The validator has been exercised with Coq 8.16.1 and 8.20.1 and freshly compiled,
matching support files. This is not a claim that untested future releases work
without compatibility testing. Theory realization is outside the initial scope.

.. _sec.realizations:

Theory Realizations
-------------------

Given a Why3 theory, one can use a proof assistant to make a
*realization* of this theory, that is to provide definitions for some of
its uninterpreted symbols and proofs for some of its axioms. This way,
one can show the consistency of an axiomatized theory and/or make a
connection to an existing library (of the proof assistant) to ease some
proofs.

Generating a realization
~~~~~~~~~~~~~~~~~~~~~~~~

Generating the skeleton for a theory is done by passing to the
:why3:tool:`realize` command a driver suitable for realizations, the names of the
theories to realize, and a target directory.

::

    why3 realize -D path/to/drivers/prover-realize.drv
                 -T env_path.theory_name -o path/to/target/dir/

The theory is looked into the files from the environment, e.g., the standard
library. If the theory is stored in a different location, option :option:`why3 -L`
should be used.

The name of the generated file is inferred from the theory name. If the
target directory already contains a file with the same name, Why3
extracts all the parts that it assumes to be user-edited and merges them
in the generated file.

Note that Why3 does not track dependencies between realizations and
theories, so a realization will become outdated if the corresponding
theory is modified. It is up to the user to handle such dependencies,
for instance using a :file:`Makefile`.

.. index:: driver file

Using realizations inside proofs
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

If a theory has been realized, the Why3 printer for the corresponding
prover will no longer output declarations for that theory but instead
simply put a directive to load the realization. In order to tell the
printer that a given theory is realized, one has to add a :why3:meta:`realized_theory` meta
declaration in the corresponding theory section of the driver.

::

    theory env_path.theory_name
      meta "realized_theory" "env_path.theory_name", "optional_naming"
    end

The first parameter is the theory name for Why3. The second parameter,
if not empty, provides a name to be used inside generated scripts to
point to the realization, in case the default name is not suitable for
the interactive prover.

.. index:: configuration file

Shipping libraries of realizations
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

While modifying an existing driver file might be sufficient for local
use, it does not scale well when the realizations are to be shipped to
other users. Instead, one should create two additional files: a
configuration file that indicates how to modify paths, provers, and
editors, and a driver file that contains only the needed
:why3:meta:`realized_theory` meta declarations. The configuration file should
be as follows.

::

    [main]
    loadpath="path/to/theories"

    [prover_modifiers]
    name="Coq"
    option="-R path/to/vo/files Logical_directory"
    driver="path/to/file/with/meta.drv"

    [editor_modifiers coqide]
    option="-R path/to/vo/files Logical_directory"

    [editor_modifiers proofgeneral-coq]
    option="--eval \"(setq coq-load-path (cons '(\\\"path/to/vo/files\\\" \
      \\\"Logical_directory\\\") coq-load-path))\""

This configuration file can be passed to Why3 thanks to the
:option:`why3 --extra-config` option.

.. index:: Coq proof assistant, proof assistant; Coq
.. _sec.coq:

Coq
---

This section describes the content of the Coq files generated by Why3
for both proof obligations and theory realizations. When reading a Coq
script, Why3 is guided by the presence of empty lines to split the
script, so the user should refrain from removing empty lines around
generated blocks or adding empty lines inside them.

#. The header of the file contains all the library inclusions required
   by the driver file. Any user-made changes to this block will be lost
   when the file is regenerated by Why3. This part starts with
   ``(* This file is generated by ... *)``.

#. Abstract logic symbols are assumed with the vernacular directive
   ``Parameter``. Axioms are assumed with the ``Axiom`` directive. When
   regenerating a script, Why3 assumes that all such symbols have been
   generated by a previous run. As a consequence, the user should not
   introduce new symbols with these two directives, as they would be
   lost.

#. Definitions of functions and inductive types in theories are printed
   in a block that starts with ``(* Why3 assumption *)``. This comment
   should not be removed; otherwise Why3 will assume that the definition
   is a user-defined block.

#. Proof obligations and symbols to be realized are introduced by
   ``(* Why3 goal *)``. The user is supposed to fill the script after
   the statement. Why3 assumes that the user-made part extends up to
   ``Qed``, ``Admitted``, ``Save``, or ``Defined``, whichever comes
   first. In the case of definitions, the original statement can be
   replaced by a ``Notation`` directive, in order to ease the usage of
   predefined symbols. Why3 also recognizes ``Variable`` and
   ``Hypothesis`` and preserves them; they should be used in conjunction
   with Coq’s ``Section`` mechanism to realize theories that still need
   some abstract symbols and axioms.

Why3 preserves any block from the script that does not fall into one of
the previous categories. Such blocks can be used to import other
libraries than the ones from the prelude. They can also be used to state
and prove auxiliary lemmas. Why3 tries to preserve the position of these
user-defined blocks relatively to the generated ones.

Currently, the parser for Coq scripts is rather naive and does not know
much about comments. For instance, Why3 can easily be confused by some
terminating directive like ``Qed`` that would be present in a comment.

.. index:: Isabelle proof assistant, proof assistant; Isabelle
.. _sec.isabelle:

Isabelle/HOL
------------

When using Isabelle from Why3, files generated from Why3 theories and
goals are stored in a dedicated XML format. Those files should not be
edited. Instead, the proofs must be completed in a file with the same
name and extension ``.thy``. This is the file that is opened when using
the :menuselection:`Tools --> Edit` action in the Why3 IDE.

Installation
~~~~~~~~~~~~

You need version Isabelle2018 or Isabelle2019. Former or later versions are not
supported. We assume below that your version is 2019, please replace
2019 by 2018 otherwise.

Isabelle must be installed before compiling Why3. After compilation and
installation of Why3, you must manually add the path

::

    <Why3 lib dir>/isabelle

into either the user file

::

    .isabelle/Isabelle2019/etc/components

or the system-wide file

::

    <Isabelle install dir>/etc/components

Usage
~~~~~

The most convenient way to call Isabelle for discharging a Why3 goal is
to start the Isabelle/jedit interface in server mode. In this mode, one
must start the server once, before launching :why3:tool:`why3 ide`, using

::

    isabelle why3_jedit

Then, inside a Why3 interactive session, any use
of :menuselection:`Tools --> Edit` will transfer the file to the already
opened instance of :program:`jEdit`. When the proof is completed, the
user must send back the edited proof to Why3 IDE by closing
the opened buffer, typically by hitting :kbd:`Control-w`.

Using Isabelle server
~~~~~~~~~~~~~~~~~~~~~

Starting from Isabelle version 2018, Why3 is able to exploit the server
features of Isabelle to speed up the processing of proofs in batch mode,
e.g., when replaying them from within Why3 IDE. Currently, when replaying
proofs using the :program:`isabelle why3` tool, an Isabelle process including a
rather heavyweight Java/Scala and PolyML runtime environment has to be
started, and a suitable heap image has to be loaded for each proof
obligation, which can take several seconds. To avoid this overhead, an
Isabelle server and a suitable session can be started once, and then
:program:`isabelle why3` can just connect to it and request the server to
process theories. In order to allow a tool such as Why3 IDE to use the
Isabelle server, it has to be started via the wrapper tool
:program:`isabelle use_server`. For example, to process the proofs in
:file:`examples/logic/genealogy` using Why3 IDE and the Isabelle server, do the
following:

#. Start an Isabelle server using

   ::

          isabelle server &

#. Start Why3 IDE using

   ::

          isabelle use_server why3 ide genealogy

Realizations
~~~~~~~~~~~~

Realizations must be designed in some :file:`.thy` as follows. The
realization file corresponding to some Why3 file :file:`f.why` should have
the following form.

::

    theory Why3_f
    imports Why3_Setup
    begin

    section {* realization of theory T *}

    why3_open "f/T.xml"

    why3_vc <some lemma>
    <proof>

    why3_vc <some other lemma> by proof

    [...]

    why3_end

See directory :file:`lib/isabelle` for examples.

.. index:: PVS proof assistant, proof assistant; PVS
.. _sec.pvs:

PVS
---

Installation
~~~~~~~~~~~~

You need version 6.0.

Usage
~~~~~

When a PVS file is regenerated, the old version is split into chunks,
according to blank lines. Chunks corresponding to Why3 declarations are
identified with a comment starting with ``% Why3``, e.g.,

::

      % Why3 f
      f(x: int) : int

Other chunks are considered to be user PVS declarations. Thus a comment
such as ``% Why3 f`` must not be removed; otherwise, there will be two
declarations for ``f`` in the next version of the file (one being
regenerated and another one considered to be a user-edited chunk).

Realization
~~~~~~~~~~~

The user is allowed to perform the following actions on a PVS
realization:

-  give a definition to an uninterpreted symbol (type, function, or
   predicate symbol), by adding an equal sign (``=``) and a right-hand
   side to the definition. When the declaration is regenerated, the
   left-hand side is updated and the right-hand side is reprinted as is.
   In particular, the names of a function or predicate arguments should
   not be modified. In addition, the ``MACRO`` keyword may be inserted
   and it will be kept in further generations.

-  turn an axiom into a lemma, that is to replace the PVS keyword
   ``AXIOM`` with either ``LEMMA`` or ``THEOREM``.

-  insert anything between generated declarations, such as a lemma, an
   extra definition for the purpose of a proof, an extra ``IMPORTING``
   command, etc. Do not forget to surround these extra declarations with
   blank lines.

Why3 makes some effort to merge new declarations with old ones and with
user chunks. If it happens that some chunks could not be merged, they
are appended at the end of the file, in comments.
