(********************************************************************)
(* The Why3 Verification Platform / The Why3 Development Team         *)
(* Copyright 2010-2026 -- Inria - CNRS - Paris-Saclay University        *)
(* Distributed under the GNU LGPL version 2.1, with the exception      *)
(* described in the file LICENSE.                                    *)
(********************************************************************)

(** Isolated local jobs with parent-side finalization. No prover, session,
    configuration, or agent-specific types belong in this module. *)
type 'a failure =
  | Timeout of float
  | Work_failed of exn * float
  | Terminated
  | Missing_result
  | Finish_failed of exn * 'a

type 'a update = No_updates | Started | Finished of 'a | Interrupted
type 'a t

val create : on_failure:('a failure -> 'a) -> 'a t
val submit :
  'a t -> timeout:float -> max_parallel:int ->
  ?on_finish:('a -> 'a) -> ?on_interrupt:(unit -> unit) ->
  (unit -> 'a) -> int
val has_pending : 'a t -> bool
val poll : 'a t -> unit
val take_updates : 'a t -> (int * 'a update) list
val query : 'a t -> int -> 'a update
val interrupt : 'a t -> int -> unit
(** Timeout and interruption terminate the job's process group. Results must
    support OCaml marshalling. Finalization and cancellation run in the parent;
    work failures are converted to results inside the worker. *)
