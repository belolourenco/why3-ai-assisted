(********************************************************************)
(* The Why3 Verification Platform / The Why3 Development Team         *)
(* Copyright 2010-2026 -- Inria - CNRS - Paris-Saclay University        *)
(* Distributed under the GNU LGPL version 2.1, with the exception      *)
(* described in the file LICENSE.                                    *)
(********************************************************************)

(** Shared external-proof script registration and preparation. No scheduler,
    editor process, model backend, or proof-validation policy belongs here. *)
val register :
  session:Session_itp.session -> driver:Driver.driver -> ?file:Sysutil.file_path ->
  Session_itp.proofNodeID -> Whyconf.prover -> Session_itp.proofAttemptID
(** Register a path without touching the file. Existing session associations,
    including those whose files are missing, reserve their filenames. *)

val prepare :
  session:Session_itp.session -> driver:Driver.driver -> ?file:Sysutil.file_path ->
  keep_existing:bool -> Session_itp.proofNodeID -> Whyconf.prover ->
  Session_itp.proofAttemptID * string * Call_provers.prover_result option
(** Create new scripts synchronously, using the driver's preservation parser.
    With [keep_existing], leave existing unshared files untouched and relocate
    shared associations without changing the shared original. Otherwise refresh
    the existing script and keep its previous contents in a [.bak] file. *)
