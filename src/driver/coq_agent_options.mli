(********************************************************************)
(* The Why3 Verification Platform / The Why3 Development Team         *)
(* Copyright 2010-2026 -- Inria - CNRS - Paris-Saclay University        *)
(* Distributed under the GNU LGPL version 2.1, with the exception      *)
(* described in the file LICENSE.                                    *)
(********************************************************************)

(** Dependency-free option declaration, usable by common argument parsing
    without loading the agent configuration parser or its backend. *)
val profile_override : string option ref
val profile_option : Getopt.opt
