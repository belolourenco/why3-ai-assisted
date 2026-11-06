(********************************************************************)
(* The Why3 Verification Platform / The Why3 Development Team         *)
(* Copyright 2010-2026 -- Inria - CNRS - Paris-Saclay University        *)
(* Distributed under the GNU LGPL version 2.1, with the exception      *)
(* described in the file LICENSE.                                    *)
(********************************************************************)

(** The feature-specific adapter between Why3's raw configuration layers and
    the agent settings schema. Neither Whyconf nor its main record interprets
    model settings, credentials, profiles, or their overlay semantics. *)
val load : main:Whyconf.main -> ?agent:Whyconf.config_agent -> unit -> Coq_agent_config.t
val rc_of_config : Whyconf.config -> Rc.t
(** Extend the standard configuration display with effective native agent
    sections. Ordinary configuration serialization remains in Whyconf. *)
