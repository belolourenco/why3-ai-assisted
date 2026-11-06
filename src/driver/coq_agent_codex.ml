(********************************************************************)
(* The Why3 Verification Platform / The Why3 Development Team         *)
(* Copyright 2010-2026 -- Inria - CNRS - Paris-Saclay University        *)
(* Distributed under the GNU LGPL version 2.1, with the exception      *)
(* described in the file LICENSE.                                    *)
(********************************************************************)

module C = Coq_agent_config
module P = Coq_agent_process

type report = { process : P.result; version : string; usage : Json_base.json list }

let error message = raise (C.Error message)
let contains text part =
  try ignore (Re.Str.search_forward (Re.Str.regexp_string part) text 0); true
  with Not_found -> false

let check_system_permissions () =
  (* Codex gives legacy sandbox settings priority over permission profiles.
     Refuse a known conflicting system layer rather than silently weakening the
     proof workspace policy. Personal config is excluded by the CLI flag. *)
  let legacy = Re.Str.regexp
      "^[ \t]*\\([\"']?sandbox_mode[\"']?[ \t]*=\\|\\[[ \t]*[\"']?sandbox_workspace_write\\)" in
  List.iter (fun filename -> if Sys.file_exists filename then begin
    let text = try P.read_file filename with Sys_error _ ->
      error "Cannot verify the system Codex permission configuration" in
    if List.exists (fun line -> Re.Str.string_match legacy line 0)
        (String.split_on_char '\n' text) then
      error "System Codex configuration uses legacy sandbox settings; migrate it to permission profiles before running Coq agents"
  end) ["/etc/codex/config.toml"]

let generate config profile ~directory ~read_paths ~timeout ~prompt =
  check_system_permissions ();
  let executable = P.find_executable config.C.executable in
  (* Give denied directory entries their correct filesystem kind. Otherwise
     some bubblewrap versions materialize a missing deny path as a file, which
     conflicts with Codex's built-in workspace-directory safeguards. *)
  List.iter (fun name ->
    let path = Filename.concat directory name in
    if not (Sys.file_exists path) then Unix.mkdir path 0o500;
    if not (Sys.is_directory path) then error "Invalid Codex workspace instruction directory")
    [".codex"; ".agents"];
  let key = match config.C.auth with
    | C.Chatgpt -> None
    | C.Api_key (C.Environment variable) ->
        match Sys.getenv_opt variable with
        | Some key when String.trim key <> "" -> Some key
        | _ -> error ("Missing Coq agent API-key environment variable: " ^ variable) in
  let redact text = match key with
    | None -> text
    | Some key -> Re.Str.global_replace (Re.Str.regexp_string key) "<redacted>" text in
  let env = Array.to_list (Unix.environment ()) |> List.filter (fun entry ->
    not (List.exists (fun prefix -> Strings.has_prefix ~prefix entry)
      (["OPENAI_API_KEY="; "CODEX_API_KEY="] @ match config.C.auth with
       | C.Api_key (C.Environment name) -> [name ^ "="]
       | _ -> []))) in
  let env = Array.of_list (match key with None -> env | Some key -> ("CODEX_API_KEY=" ^ key) :: env) in
  let probe arguments =
    let result = P.run ~env ~cwd:directory ~timeout:(min timeout 10.) (executable :: arguments) in
    if not (P.succeeds result) then error ("Codex setup check failed: " ^ redact result.P.output);
    result.P.output in
  let version = String.trim (redact (probe ["--version"])) in
  let help = probe ["exec"; "--help"] in
  List.iter (fun flag -> if not (contains help flag) then
      error ("This Codex CLI lacks " ^ flag ^ "; update Codex before using the Coq agent"))
    (["--json"; "--strict-config"; "--model"; "--cd"; "--skip-git-repo-check"] @
     (if config.C.ephemeral then ["--ephemeral"] else []) @
     (if config.C.ignore_user_config then ["--ignore-user-config"; "--ignore-rules"] else []));
  if config.C.auth = C.Chatgpt then begin
    let status = P.run ~env ~cwd:directory ~timeout:(min timeout 10.)
        [executable; "login"; "status"] in
    if not (P.succeeds status && contains status.P.output "Logged in using ChatGPT") then
      error "Coq agent requires Sign in with ChatGPT: run 'codex login' outside Why3. Existing authentication was not changed."
  end;
  let setting name value = ["-c"; name ^ "=" ^ value] in
  let auth_home = match Sys.getenv_opt "CODEX_HOME", Sys.getenv_opt "HOME" with
    | Some path, _ -> path
    | None, Some path -> Filename.concat path ".codex"
    | _ -> error "Cannot locate Codex's credential directory" in
  let runtime = Filename.dirname (Unix.realpath executable) in
  (* The standalone CLI also launches its packaged sandbox helper. These are
     executable/runtime files, not its credential store. *)
  let read_paths = runtime :: Filename.concat auth_home "tmp/arg0-linux" ::
    Filename.concat auth_home "tmp/arg0" :: read_paths
    |> List.filter Sys.file_exists in
  let rules = [":root", "deny"; ":minimal", "read"] @
    List.map (fun path -> path, "read") read_paths @
    List.concat_map (fun path -> [path,"deny";
      (try Unix.realpath path with Unix.Unix_error _ -> path),"deny"]) config.C.source_files @
    [directory, "write"; Filename.concat auth_home "auth.json", "deny";
     Filename.concat auth_home "config.toml", "deny";
     Filename.concat directory ".codex", "deny";
     Filename.concat directory ".agents", "deny";
     Filename.concat directory "AGENTS.md", "deny"] in
  let rules = List.fold_left (fun rules (path, mode) -> Wstdlib.Mstr.add path mode rules)
      Wstdlib.Mstr.empty rules |> Wstdlib.Mstr.bindings in
  let filesystem = "{" ^ String.concat "," (List.map (fun (path, mode) ->
    Printf.sprintf "%S=%S" path mode) rules) ^ "}" in
  let permissions = "{filesystem=" ^ filesystem ^ ",network={enabled=" ^
    string_of_bool config.C.shell_network_access ^ "}}" in
  let args = [executable; "exec"; "--json"; "--strict-config"; "--color"; "never";
      "--model"; profile.C.model;
      "--cd"; directory; "--skip-git-repo-check"] @
    (if config.C.ephemeral then ["--ephemeral"] else []) @
    (if config.C.ignore_user_config then ["--ignore-user-config"; "--ignore-rules"] else []) @
    setting "model_reasoning_effort" (Printf.sprintf "%S" profile.C.reasoning_effort) @
    setting "approval_policy" "\"never\"" @
    setting "default_permissions" "\"why3-coq-agent\"" @
    setting "permissions.why3-coq-agent" permissions @
    setting "web_search" "\"disabled\"" @
    setting "features.multi_agent" "false" @
    setting "features.apps" "false" @
    setting "project_doc_max_bytes" "0" @
    setting "shell_environment_policy.ignore_default_excludes" "false" @
    setting "shell_environment_policy.exclude" "[\"*KEY*\",\"*SECRET*\",\"*TOKEN*\"]" @ ["-"] in
  let result = P.run ~env ~stdin:prompt ~cwd:directory ~timeout args in
  let process = {result with P.output = redact result.P.output} in
  let usage = String.split_on_char '\n' process.P.output |> List.filter_map (fun line ->
    try
      let json = Json_parser.document Json_lexer.read (Lexing.from_string line) in
      if Json_base.get_string_field json "type" <> "turn.completed" then None else
        let usage = Json_base.get_field json "usage" in
        (* Persist only numerical usage fields, never arbitrary runner content. *)
        let fields = ["input_tokens"; "cached_input_tokens"; "output_tokens"]
          |> List.filter_map (fun name -> try
            let value = Json_base.get_int_field usage name in
            if value < 0 then None else Some (name, Json_base.Int value)
            with _ -> None) in
        Some (Json_base.Record fields)
    with _ -> None) in
  {process; version; usage}

