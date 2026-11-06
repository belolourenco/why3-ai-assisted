(********************************************************************)
(* The Why3 Verification Platform / The Why3 Development Team         *)
(* Copyright 2010-2026 -- Inria - CNRS - Paris-Saclay University        *)
(* Distributed under the GNU LGPL version 2.1, with the exception      *)
(* described in the file LICENSE.                                    *)
(********************************************************************)

(** Local, bounded subprocess execution for the Coq agent adapter. *)

type result = { status : Unix.process_status; output : string; timed_out : bool }

val read_file : string -> string
val write_file : string -> string -> unit
val directory : string -> string
val find_executable : string -> string
val run :
  ?env:string array -> ?stdin:string -> cwd:string -> timeout:float ->
  string list -> result
(** Arguments are passed directly, without a shell. Output is captured in a
    private file. Child processes inherit the caller's process group. *)

val succeeds : result -> bool
val sleep : float -> unit
