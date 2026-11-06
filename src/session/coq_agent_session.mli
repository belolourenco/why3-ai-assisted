(********************************************************************)
(* The Why3 Verification Platform / The Why3 Development Team         *)
(* Copyright 2010-2026 -- Inria - CNRS - Paris-Saclay University        *)
(* Distributed under the GNU LGPL version 2.1, with the exception      *)
(* described in the file LICENSE.                                    *)
(********************************************************************)

(** Agent policy at the session boundary, independent of the IDE scheduler. *)
val prepare :
  mode:Coq_agent.mode -> session:Session_itp.session -> driver:Driver.driver ->
  ?file:Sysutil.file_path -> Session_itp.proofNodeID -> Whyconf.prover -> string

val guard :
  session:Session_itp.session -> current_session:(unit -> Session_itp.session) ->
  goal:Session_itp.proofNodeID -> attempt:Session_itp.proofAttemptID ->
  prover:Whyconf.prover -> unit -> bool
(** Reject publication after the source, session, goal task, or attempt changes. *)
