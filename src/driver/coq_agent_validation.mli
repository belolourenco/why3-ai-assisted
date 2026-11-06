(********************************************************************)
(* The Why3 Verification Platform / The Why3 Development Team         *)
(* Copyright 2010-2026 -- Inria - CNRS - Paris-Saclay University        *)
(* Distributed under the GNU LGPL version 2.1, with the exception      *)
(* described in the file LICENSE.                                    *)
(********************************************************************)

(** Restricted agent-output gate, ordinary Coq checking and result audit. *)

type t
exception Rejected of string

val create :
  main:Whyconf.main -> prover:Whyconf.config_prover -> directory:string ->
  source:string -> timeout:float -> memory:int -> t

val check : ?regenerate:(in_channel -> string) -> t -> candidate:string -> (string, string) result
(** On success return the exact independently checked standalone script.
    The gate preserves the generated context/VC, moves extra imports inside
    Proof, and permits only a restricted proof-command subset. Production callers
    supply ordinary [Driver.print_task ~old] regeneration. The configured original
    Coq command checks that script in its normal standalone context. A separate
    compiled-result audit checks theorem existence, assumptions and unsafe
    declarations. There is no module-signature check or imported proof context.
    Imported compiled libraries remain trusted original-environment inputs. *)

val goal : t -> string

val feedback_command : t -> string -> string list
(** Bounded compiler command for the agent's standalone candidate. *)

val read_paths : t -> string list
(** Installation and configured library paths needed by sandboxed feedback. *)
