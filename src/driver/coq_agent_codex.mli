(********************************************************************)
(* The Why3 Verification Platform / The Why3 Development Team         *)
(* Copyright 2010-2026 -- Inria - CNRS - Paris-Saclay University        *)
(* Distributed under the GNU LGPL version 2.1, with the exception      *)
(* described in the file LICENSE.                                    *)
(********************************************************************)

(** Codex CLI adapter. Credentials remain owned by Codex. *)
type report = {
  process : Coq_agent_process.result;
  version : string;
  usage : Json_base.json list;
}
val generate :
  Coq_agent_config.t -> Coq_agent_config.profile ->
  directory:string -> read_paths:string list -> timeout:float -> prompt:string -> report

