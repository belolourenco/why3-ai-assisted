(********************************************************************)
(* The Why3 Verification Platform / The Why3 Development Team         *)
(* Copyright 2010-2026 -- Inria - CNRS - Paris-Saclay University        *)
(* Distributed under the GNU LGPL version 2.1, with the exception      *)
(* described in the file LICENSE.                                    *)
(********************************************************************)

(** Shared orchestration for explicit proof generation and offline replay. *)
type mode = Generate | Check

val prove_task :
  mode:mode -> main:Whyconf.main -> prover:Whyconf.config_prover ->
  driver:Driver.driver -> script:string ->
  ?is_current:(unit -> bool) -> ?wall_time:float -> ?check_memory:int ->
  Task.task -> Call_provers.prover_call
(** Only independently checked proofs are published. [Check] never loads agent
    settings or starts Codex. [is_current] is evaluated in the parent process
    immediately before publication. Generation uses the profile's own budget. *)
