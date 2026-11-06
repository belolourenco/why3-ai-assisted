(********************************************************************)
(* The Why3 Verification Platform / The Why3 Development Team         *)
(* Copyright 2010-2026 -- Inria - CNRS - Paris-Saclay University        *)
(* Distributed under the GNU LGPL version 2.1, with the exception      *)
(* described in the file LICENSE.                                    *)
(********************************************************************)

(** Configuration of the Codex-backed Coq prover. Loading configuration
    never starts Codex, reads its login cache, or resolves an API key. *)

type key_source = Environment of string
type authentication = Chatgpt | Api_key of key_source

type profile = {
  model : string;
  reasoning_effort : string;
  wall_time_seconds : int;
  max_generation_attempts : int;
}

type t = {
  filename : string;
  source_files : string list; (** Configuration inputs denied to agent tools. *)
  auth : authentication;
  executable : string;
  ephemeral : bool;
  ignore_user_config : bool;
  default_profile : string;
  profiles : profile Wstdlib.Mstr.t;
  check_timeout_seconds : int;
  check_memory_mb : int;
  max_parallel_jobs : int;
  shell_network_access : bool;
  log_level : string;
  retain_failed_attempts : bool;
  retention_days : int;
}

exception Error of string

type rc_source
val rc_source : filename:string -> Rc.t -> rc_source
val rc_filenames : rc_source list -> string list
val has_rc_settings : rc_source list -> bool
val load_rc : rc_source list -> t
(** Load native [coq_agent] and named [coq_agent_profile] sections. Later layers
    override individual fields, with executable paths relative to their layer.
    Literal API keys are not supported in native Why3 configuration. *)

val to_rc : t -> Rc.t -> Rc.t
(** Replace native agent sections, preserving unrelated sections. Credentials
    are never stored here: API-key authentication uses an environment reference. *)

val select_profile : ?name:string -> t -> string * profile

val profile_override : string option ref
(** Explicit command-line profile override; configuration is loaded lazily so ordinary
    prover discovery and proof replay do not require agent credentials. *)

