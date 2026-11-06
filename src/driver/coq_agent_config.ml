(********************************************************************)
(* The Why3 Verification Platform / The Why3 Development Team         *)
(* Copyright 2010-2026 -- Inria - CNRS - Paris-Saclay University        *)
(* Distributed under the GNU LGPL version 2.1, with the exception      *)
(* described in the file LICENSE.                                    *)
(********************************************************************)

open Wstdlib
open Json_base

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
  source_files : string list;
  auth : authentication;
  executable : string;
  ephemeral : bool;
  ignore_user_config : bool;
  default_profile : string;
  profiles : profile Mstr.t;
  check_timeout_seconds : int;
  check_memory_mb : int;
  max_parallel_jobs : int;
  shell_network_access : bool;
  log_level : string;
  retain_failed_attempts : bool;
  retention_days : int;
}

exception Error of string

type rc_source = { rc_filename : string; rc : Rc.t }
let rc_source ~filename rc =
  let filename = if filename = "" then ".why3-agent-in-memory.conf" else filename in
  { rc_filename = Sysutil.concat (Sys.getcwd ()) filename; rc }
let rc_filenames sources = List.map (fun source -> source.rc_filename) sources

let has_rc_settings sources = List.exists (fun source ->
  Rc.get_section source.rc "coq_agent" <> None ||
  Rc.get_family source.rc "coq_agent_profile" <> []) sources

let profile_override = Coq_agent_options.profile_override

let error field message =
  raise (Error (Printf.sprintf "Coq agent configuration: %s %s" field message))

let absolute path = Sysutil.concat (Sys.getcwd ()) path

let object_fields field allowed = function
  | Record fields ->
      ignore (List.fold_left (fun seen (key, _) ->
        if not (List.mem key allowed) then error field ("has unknown field " ^ key);
        if Sstr.mem key seen then error field ("has duplicate field " ^ key);
        Sstr.add key seen) Sstr.empty fields);
      fields
  | _ -> error field "must be an object"

let get fields name = List.assoc_opt name fields

let string field = function
  | String s when String.trim s <> "" -> s
  | _ -> error field "must be a nonempty string"

let boolean field = function
  | Bool b -> b
  | _ -> error field "must be a boolean"

let positive field = function
  | Int n when n > 0 -> n
  | _ -> error field "must be a positive integer"

let optional parse fields name default =
  match get fields name with None -> default | Some v -> parse name v

let required parse fields name =
  match get fields name with
  | Some v -> parse name v
  | None -> error name "is required"

let enumeration ~allowed field value =
  let s = string field value in
  if not (List.mem s allowed) then error field "has an unsupported value";
  s

let configured_string field value =
  let s = string field value in
  if Strings.has_prefix ~prefix:"REPLACE_WITH_" s then
    error field "contains an example placeholder; replace it during setup";
  s

let environment_name field value =
  let s = string field value in
  String.iteri (fun i c ->
    match c with
    | 'a' .. 'z' | 'A' .. 'Z' | '_' -> ()
    | '0' .. '9' when i > 0 -> ()
    | _ -> error field "must be an environment variable name") s;
  s

let parse_auth = function
  | None -> Chatgpt
  | Some value ->
      let fields = object_fields "auth" ["mode"; "api_key_env"] value in
      let mode = optional (enumeration ~allowed:["chatgpt"; "api_key"])
          fields "mode" "chatgpt" in
      match mode, get fields "api_key_env" with
      | "chatgpt", None -> Chatgpt
      | "chatgpt", _ -> error "auth" "must not contain API key settings in chatgpt mode"
      | _, Some env -> Api_key (Environment (environment_name "api_key_env" env))
      | _ -> error "auth" "requires api_key_env in api_key mode"

let parse_profile name value =
  let fields = object_fields ("profiles." ^ name)
      ["model"; "reasoning_effort"; "wall_time_seconds";
       "max_generation_attempts"] value in
  { model = required configured_string fields "model";
    reasoning_effort = optional
        (enumeration ~allowed:["none"; "minimal"; "low"; "medium"; "high";
                               "xhigh"; "max"; "ultra"])
        fields "reasoning_effort" "high";
    wall_time_seconds = optional positive fields "wall_time_seconds" 600;
    max_generation_attempts = optional positive fields "max_generation_attempts" 2;
  }

let select_profile ?name config =
  let name = Option.value ~default:config.default_profile name in
  match Mstr.find_opt name config.profiles with
  | Some profile -> name, profile
  | None -> error "profile" ("is not defined: " ^ name)

(* JSON values are only an internal representation for merging typed RC fields;
   no JSON configuration parser or file lookup is provided. *)
let decode_settings ~filename value =
  let fields = object_fields "root"
      ["schema_version"; "backend"; "auth"; "codex"; "default_profile";
       "profiles"; "coq"; "execution"; "logging"] value in
  if required positive fields "schema_version" <> 1 then
    error "schema_version" "is unsupported (expected 1)";
  ignore (optional (enumeration ~allowed:["codex"]) fields "backend" "codex");
  let section name allowed =
    match get fields name with
    | None -> []
    | Some value -> object_fields name allowed value
  in
  let codex = section "codex" ["executable"; "ephemeral"; "ignore_user_config"] in
  let coq = section "coq" ["check_timeout_seconds"; "check_memory_mb"] in
  let execution = section "execution"
      ["max_parallel_jobs"; "sandbox"; "approval_policy"; "shell_network_access"] in
  let logging = section "logging"
      ["level"; "retain_failed_attempts"; "retention_days"] in
  let profiles = match get fields "profiles" with
    | Some (Record profiles) when profiles <> [] ->
        List.fold_left (fun acc (name, value) ->
          if String.trim name = "" then error "profiles" "contains an empty name";
          if Mstr.mem name acc then error "profiles" ("has duplicate profile " ^ name);
          Mstr.add name (parse_profile name value) acc) Mstr.empty profiles
    | _ -> error "profiles" "must contain at least one named model profile"
  in
  ignore (optional (enumeration ~allowed:["workspace-write"])
            execution "sandbox" "workspace-write");
  ignore (optional (enumeration ~allowed:["never"])
            execution "approval_policy" "never");
  let filename = absolute filename in
  let executable = optional string codex "executable" "codex" in
  let executable =
    if Filename.basename executable = executable then executable
    else Sysutil.concat (Filename.dirname filename) executable
  in
  let config = {
    filename;
    source_files = [filename];
    auth = parse_auth (get fields "auth");
    executable;
    ephemeral = optional boolean codex "ephemeral" true;
    ignore_user_config = optional boolean codex "ignore_user_config" true;
    default_profile = optional string fields "default_profile" "proof";
    profiles;
    check_timeout_seconds = optional positive coq "check_timeout_seconds" 20;
    check_memory_mb = optional positive coq "check_memory_mb" 1000;
    max_parallel_jobs = optional positive execution "max_parallel_jobs" 1;
    shell_network_access = optional boolean execution "shell_network_access" false;
    log_level = optional (enumeration ~allowed:["error"; "info"; "debug"])
        logging "level" "info";
    retain_failed_attempts = optional boolean logging "retain_failed_attempts" true;
    retention_days = optional positive logging "retention_days" 7;
  } in
  if not config.ignore_user_config then
    error "codex.ignore_user_config" "must be true to keep proof execution isolated from personal Codex settings";
  ignore (select_profile config);
  config

let encode_settings config =
  let auth = match config.auth with
    | Chatgpt -> ["mode", String "chatgpt"]
    | Api_key (Environment name) ->
        ["mode", String "api_key"; "api_key_env", String name]
  in
  let profile p = Record [
    "model", String p.model;
    "reasoning_effort", String p.reasoning_effort;
    "wall_time_seconds", Int p.wall_time_seconds;
    "max_generation_attempts", Int p.max_generation_attempts;
  ] in
  Record [
    "schema_version", Int 1;
    "backend", String "codex";
    "auth", Record auth;
    "codex", Record ["executable", String config.executable;
                     "ephemeral", Bool config.ephemeral;
                     "ignore_user_config", Bool config.ignore_user_config];
    "default_profile", String config.default_profile;
    "profiles", Record (List.map (fun (name, p) -> name, profile p)
                          (Mstr.bindings config.profiles));
    "coq", Record ["check_timeout_seconds", Int config.check_timeout_seconds;
                   "check_memory_mb", Int config.check_memory_mb];
    "execution", Record ["max_parallel_jobs", Int config.max_parallel_jobs;
                         "sandbox", String "workspace-write";
                         "approval_policy", String "never";
                         "shell_network_access", Bool config.shell_network_access];
    "logging", Record ["level", String config.log_level;
                       "retain_failed_attempts", Bool config.retain_failed_attempts;
                       "retention_days", Int config.retention_days];
  ]

(* Native Why3 sections use flat keys. Keep raw RC layers lazy so replay and unrelated
   provers never need a configured model or credentials. *)
let rc_groups = [
  "", ["schema_version",`Int; "backend",`String; "default_profile",`String];
  "auth", ["auth",`String; "api_key_env",`String];
  "codex", ["executable",`String; "ephemeral",`Bool; "ignore_user_config",`Bool];
  "coq", ["check_timeout_seconds",`Int; "check_memory_mb",`Int];
  "execution", ["max_parallel_jobs",`Int; "sandbox",`String;
                "approval_policy",`String; "shell_network_access",`Bool];
  "logging", ["log_level",`String; "retain_failed_attempts",`Bool; "retention_days",`Int];
]
let rc_profile_keys = ["model",`String; "reasoning_effort",`String;
                      "wall_time_seconds",`Int; "max_generation_attempts",`Int]

let rc_value section (name, kind) =
  try
    match kind with
    | `String -> Option.map (fun value -> name, String value) (Rc.get_stringo section name)
    | `Int -> Option.map (fun value -> name, Int value) (Rc.get_into section name)
    | `Bool -> Option.map (fun value -> name, Bool value) (Rc.get_boolo section name)
  with _ -> error name "must occur once and have the expected value type"

let exhaustive section keys =
  try Rc.check_exhaustive section (Sstr.of_list (List.map fst keys)) with
  | Rc.UnknownField "api_key" ->
      error "api_key" "cannot be stored in why3.conf; use api_key_env instead"
  | Rc.UnknownField name -> error name "is not supported in the native Why3 agent configuration"

let rc_json source =
  let section = Option.value ~default:Rc.empty_section (Rc.get_section source.rc "coq_agent") in
  exhaustive section (List.concat_map snd rc_groups);
  let groups = List.concat_map (fun (group, keys) ->
    let fields = List.filter_map (rc_value section) keys |> List.map (fun (key, value) ->
      let key = match key with "auth" -> "mode" | "log_level" -> "level" | key -> key in
      let value = if group = "codex" && key = "executable" then match value with
        | String path when Filename.basename path <> path ->
            String (Sysutil.concat (Filename.dirname (absolute source.rc_filename)) path)
        | value -> value
      else value in key, value) in
    if group = "" then fields else if fields = [] then [] else [group, Record fields]) rc_groups in
  let _, profiles = List.fold_left (fun (seen, profiles) (name, section) ->
    if Sstr.mem name seen then error "profiles" ("has duplicate profile " ^ name);
    exhaustive section rc_profile_keys;
    Sstr.add name seen, (name, Record (List.filter_map (rc_value section) rc_profile_keys)) :: profiles)
      (Sstr.empty, []) (Rc.get_family source.rc "coq_agent_profile") in
  Record (groups @ if profiles = [] then [] else ["profiles",Record (List.rev profiles)])

let rec merge_json previous newer = match previous, newer with
  | Record old, Record fields ->
      Record (List.fold_left (fun acc (name, value) ->
        let value = match List.assoc_opt name acc with
          | None -> value | Some previous -> merge_json previous value in
        List.remove_assoc name acc @ [name,value]) old fields)
  | _, value -> value

let load_rc sources =
  let source_files = List.sort_uniq String.compare (rc_filenames sources) in
  let sources = List.filter (fun source -> has_rc_settings [source]) sources in
  let json = List.fold_left (fun json source -> merge_json json (rc_json source))
      (Record ["schema_version",Int 1]) sources in
  let filename = match List.rev sources with
    | source :: _ -> source.rc_filename
    | [] -> error "configuration" "has no [coq_agent] or [coq_agent_profile] sections; add them to your Why3 configuration (see coqagent.conf.example)" in
  { (decode_settings ~filename json) with source_files }

let to_rc config rc =
  let json = encode_settings config in
  let set section name = function
    | String value -> Rc.set_string section name value
    | Int value -> Rc.set_int section name value
    | Bool value -> Rc.set_bool section name value
    | _ -> assert false in
  let section = List.fold_left (fun section (group, keys) ->
    let object_ = if group = "" then json else Json_base.get_field json group in
    List.fold_left (fun section (key, _) ->
      let field = match key with "auth" -> "mode" | "log_level" -> "level" | key -> key in
      match (try Some (Json_base.get_field object_ field) with Not_found -> None) with
      | None -> section | Some value -> set section key value) section keys)
      Rc.empty_section rc_groups in
  let profiles = Mstr.bindings config.profiles |> List.map (fun (name, profile) ->
    let section = Rc.empty_section
      |> fun s -> Rc.set_string s "model" profile.model
      |> fun s -> Rc.set_string s "reasoning_effort" profile.reasoning_effort
      |> fun s -> Rc.set_int s "wall_time_seconds" profile.wall_time_seconds
      |> fun s -> Rc.set_int s "max_generation_attempts" profile.max_generation_attempts in
    name, section) in
  Rc.set_section rc "coq_agent" section |> fun rc -> Rc.set_family rc "coq_agent_profile" profiles

let () = Exn_printer.register (fun fmt -> function
  | Error message -> Format.pp_print_string fmt message
  | exn -> raise exn)
