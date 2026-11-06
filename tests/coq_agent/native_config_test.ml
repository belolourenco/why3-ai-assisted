open Why3
module C = Coq_agent_config
module P = Coq_agent_process

let check message condition = if not condition then failwith message
let rejects message f = match f () with
  | _ -> failwith ("expected rejection: " ^ message)
  | exception C.Error text ->
      check ("diagnostic: " ^ text)
        (try ignore (Re.Str.search_forward (Re.Str.regexp_string message) text 0); true
         with Not_found -> false)

let () =
  let directory = P.directory "why3-agent-native-config-" in
  let filename = Filename.concat directory "why3.conf" in
  let header = "[main]\nmagic = 14\n" in
  let native = "[coq_agent]\nauth = \"chatgpt\"\nexecutable = \"tools/codex\"\n" ^
    "default_profile = \"proof\"\ncheck_timeout_seconds = 30\n\n" ^
    "[coq_agent_profile proof]\nmodel = \"base-model\"\nreasoning_effort = \"high\"\n" ^
    "wall_time_seconds = 123\n" in
  P.write_file filename (header ^ native ^ "\n[ide]\nwindow_width = 900\n");
  let load filename = Whyconf.read_config (Some filename) in
  let settings config = Coq_agent_settings.load ~main:(Whyconf.get_main config) () in
  let config = load filename in
  let c = settings config in
  check "native settings selected" (c.C.auth = C.Chatgpt && c.C.check_timeout_seconds = 30);
  check "native executable path anchored to config" (c.C.executable = Filename.concat directory "tools/codex");
  let _, p = C.select_profile c in
  check "native profile and defaults" (p.C.model = "base-model" && p.C.wall_time_seconds = 123 && p.C.max_generation_attempts = 2);
  let overlay_dir = Filename.concat directory "overlay" in
  Unix.mkdir overlay_dir 0o700;
  let overlay = Filename.concat overlay_dir "extra.conf" in
  P.write_file overlay ("[coq_agent]\nexecutable = \"other/codex\"\n" ^
    "[coq_agent_profile proof]\nreasoning_effort = \"low\"\n" ^
    "[coq_agent_profile quick]\nmodel = \"quick-model\"\nwall_time_seconds = 42\n");
  let merged = Whyconf.add_extra_config config overlay in
  let c = settings merged in
  let _, p = C.select_profile c in
  check "extra config merges individual fields" (p.C.model = "base-model" && p.C.reasoning_effort = "low" && p.C.wall_time_seconds = 123);
  check "overlay executable relative to overlay" (c.C.executable = Filename.concat overlay_dir "other/codex");
  check "all configuration layers protected from agent tools"
    (List.mem filename c.C.source_files && List.mem overlay c.C.source_files);
  let extension = Rc.set_string Rc.empty_section "value" "third-party-setting" in
  let custom = Whyconf.User.set_section merged "third_party" extension in
  let sources = Whyconf.config_sources (Whyconf.get_main custom) in
  check "generic raw layers preserve extension updates and overlays"
    (List.length sources = 2 &&
     Rc.get_string (Option.get (Rc.get_section (snd (List.hd sources)) "third_party")) "value" =
       "third-party-setting");
  C.profile_override := Some "quick";
  check "CLI profile overrides native default" ((snd (C.select_profile (settings merged))).C.model = "quick-model");
  C.profile_override := None;
  let shown = Coq_agent_settings.rc_of_config merged in
  check "normal config show includes native settings"
    (Rc.get_string (Option.get (Rc.get_section shown "coq_agent")) "executable" = c.C.executable);
  check "normal config show includes merged profiles" (List.length (Rc.get_family shown "coq_agent_profile") = 2);
  Whyconf.save_config merged;
  let reread = load filename in
  check "save preserves base, not temporary overlay" ((snd (C.select_profile (settings reread))).C.reasoning_effort = "high");
  check "IDE section survives save" (Rc.get_int (Option.get (Whyconf.User.get_section reread "ide")) "window_width" = 900);
  let rc = C.to_rc (settings merged) Rc.empty in
  let updated = Whyconf.User.set_section reread "coq_agent" (Option.get (Rc.get_section rc "coq_agent")) in
  let updated = Whyconf.User.set_family updated "coq_agent_profile" (Rc.get_family rc "coq_agent_profile") in
  check "programmatic native updates take effect" ((snd (C.select_profile (settings updated))).C.reasoning_effort = "low");
  Whyconf.save_config updated;
  check "native round trip" ((settings (load filename)).C.executable = c.C.executable);
  let agent = Whyconf.{base_prover={prover_name="Coq";prover_version="test";prover_altern=""};
    profile=Some "quick"} in
  check "per-prover profile overrides native default"
    ((snd (C.select_profile (Coq_agent_settings.load ~main:(Whyconf.get_main merged) ~agent ()))).C.model = "quick-model");
  C.profile_override := Some "proof";
  check "CLI profile overrides per-prover profile"
    ((Coq_agent_settings.load ~main:(Whyconf.get_main merged) ~agent ()).C.default_profile = "proof");
  C.profile_override := None;
  let invalid = Filename.concat directory "invalid.conf" in
  P.write_file invalid (header ^ "[coq_agent]\napi_key = \"secret-not-to-log\"\n" ^
    "[coq_agent_profile proof]\nmodel = \"model\"\n");
  let invalid_config = load invalid in
  check "invalid agent settings do not prevent ordinary config loading" (Whyconf.get_conf_file invalid_config = invalid);
  check "core configuration serialization does not interpret agent settings"
    (Rc.get_section (Whyconf.rc_of_config invalid_config) "coq_agent" = None);
  rejects "api_key" (fun () -> settings invalid_config);
  P.write_file invalid (header ^ "[coq_agent]\ncheck_memory_mb = \"wrong-type\"\n" ^
    "[coq_agent_profile proof]\nmodel = \"model\"\n");
  rejects "expected value type" (fun () -> settings (load invalid));
  P.write_file invalid (header ^ native ^ "\n[coq_agent_profile proof]\nmodel = \"other\"\n");
  rejects "duplicate profile" (fun () -> settings (load invalid));
  let api = {c with C.auth=C.Api_key (C.Environment "WHY3_NATIVE_TEST_KEY")} in
  let api = C.load_rc [C.rc_source ~filename (C.to_rc api Rc.empty)] in
  check "environment-key reference round trip" (api.C.auth = C.Api_key (C.Environment "WHY3_NATIVE_TEST_KEY"));
  let example = "../../share/coqagent.conf.example" in
  rejects "placeholder" (fun () -> C.load_rc [C.rc_source ~filename:example (Rc.from_file example)]);
  (* Even a valid old XDG file must not be consulted when native settings are absent. *)
  let xdg = Filename.concat directory "xdg" in
  Unix.mkdir xdg 0o700;
  let legacy_directory = Filename.concat xdg "why3" in
  Unix.mkdir legacy_directory 0o700;
  P.write_file (Filename.concat legacy_directory "coqagent.json")
    "{\"schema_version\":1,\"profiles\":{\"proof\":{\"model\":\"legacy-model\"}}}";
  let old_xdg = Sys.getenv_opt "XDG_CONFIG_HOME" in
  Fun.protect ~finally:(fun () -> Unix.putenv "XDG_CONFIG_HOME"
      (Option.value ~default:"" old_xdg)) (fun () ->
    Unix.putenv "XDG_CONFIG_HOME" xdg;
    rejects "Why3 configuration" (fun () -> settings (Whyconf.default_config "")));
  print_endline "Native Why3 Coq agent configuration tests passed"
