(********************************************************************)
(* The Why3 Verification Platform / The Why3 Development Team         *)
(* Copyright 2010-2026 -- Inria - CNRS - Paris-Saclay University        *)
(* Distributed under the GNU LGPL version 2.1, with the exception      *)
(* described in the file LICENSE.                                    *)
(********************************************************************)

module C = Coq_agent_config

let sources main = Whyconf.config_sources main
  |> List.map (fun (filename, rc) -> C.rc_source ~filename rc)

let load ~main ?agent () =
  let profile = match !Coq_agent_options.profile_override with
    | Some _ as name -> name
    | None -> Option.bind agent (fun agent -> agent.Whyconf.profile) in
  let config = C.load_rc (sources main) in
  let name, _ = C.select_profile ?name:profile config in
  {config with C.default_profile=name}

let rc_of_config config =
  let rc = Whyconf.rc_of_config config in
  let sources = sources (Whyconf.get_main config) in
  if C.has_rc_settings sources then C.to_rc (C.load_rc sources) rc else rc
