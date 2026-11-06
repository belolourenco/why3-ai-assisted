(********************************************************************)
(* The Why3 Verification Platform / The Why3 Development Team         *)
(* Copyright 2010-2026 -- Inria - CNRS - Paris-Saclay University        *)
(* Distributed under the GNU LGPL version 2.1, with the exception      *)
(* described in the file LICENSE.                                    *)
(********************************************************************)

(** Restricted, fail-closed framing of agent-written Coq scripts. *)
exception Rejected of string
type t

val create : string -> t
(** Capture the generated context and theorem declaration, without a proof. *)

val goal : t -> string
val context : t -> string

val prepare : t -> string -> string
(** Require the generated declarations and target to remain unchanged (modulo
    comments/whitespace). Accept only a framed proof using supported tactics,
    imports and scope commands; reject other vernacular commands. Additional
    imports preceding the goal are moved inside [Proof], so the original VC is
    elaborated before any agent-supplied command. Helpers must be local facts
    established with tactics such as [assert], not top-level declarations. *)
