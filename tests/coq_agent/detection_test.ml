open Why3
open Wstdlib
open Whyconf

let check message condition = if not condition then failwith message

let original ?(version="8.20.1") ?(altern="") ?(command="coqtop -batch -l %f") () = {
  prover = {prover_name = "Coq"; prover_version = version; prover_altern = altern};
  command; command_steps = None; driver = None, "coq"; in_place = false;
  editor = "coqide"; interactive = true; agent = None;
  extra_options = ["-R"; "custom"; "Custom"];
  extra_drivers = ["/custom", ["extra.drv"]];
}

let companion p = {p.prover with prover_altern =
  if p.prover.prover_altern = "" then "AI-assisted"
  else p.prover.prover_altern ^ "+AI-assisted"}

let with_directory f =
  let directory = Filename.temp_file "why3-coq-agent-detection-" "" in
  Sys.remove directory;
  Unix.mkdir directory 0o700;
  Fun.protect ~finally:(fun () ->
    Array.iter (fun file -> Sys.remove (Filename.concat directory file))
      (Sys.readdir directory);
    Unix.rmdir directory) (fun () -> f directory)

let write filename text =
  let channel = open_out filename in
  output_string channel text;
  close_out channel

let () =
  let base = original () in
  let initial = Mprover.singleton base.prover base in
  let expanded = coq_agent_provers initial in
  let agent = Mprover.find (companion base) expanded in
  check "companion added" (Mprover.cardinal expanded = 2);
  check "base unchanged" (Mprover.find base.prover expanded = base);
  check "exact checking environment inherited"
    (agent.command = base.command && agent.driver = base.driver &&
     agent.extra_options = base.extra_options && agent.extra_drivers = base.extra_drivers);
  check "automatic companion" (not agent.interactive);
  check "explicit association"
    (match agent.agent with Some a -> a.base_prover = base.prover | _ -> false);
  check "idempotent" (coq_agent_provers expanded = expanded);
  check "separate display identity"
    (Format.asprintf "%a" print_prover agent.prover = "Coq 8.20.1 (AI-assisted)");
  check "original still runnable"
    (get_complete_command base ~with_steps:false <> "");
  (match get_complete_command agent ~with_steps:false with
   | _ -> failwith "unfinished agent execution must be disabled"
   | exception AgentExecutionUnavailable -> ());

  let other = original ~altern:"alt" ~command:"/different/coqtop -l %f" () in
  let second_version = original ~version:"9.1.3" () in
  let expanded = coq_agent_provers
      (List.fold_left (fun m p -> Mprover.add p.prover p m) initial [other; second_version]) in
  check "multiple installations/versions" (Mprover.cardinal expanded = 6);
  check "distinct companion environment"
    ((Mprover.find (companion other) expanded).command = other.command);

  let manual = {base with prover = companion base; command = "manual-wrapper %f"} in
  let expanded = coq_agent_provers (Mprover.add manual.prover manual initial) in
  check "manual companion preserved" (Mprover.find manual.prover expanded = manual);
  check "reserved companion not recursively expanded" (Mprover.cardinal expanded = 2);

  let config = set_provers (default_config "") ~shortcuts:(Mstr.singleton "coq" base.prover) initial in
  let config = add_coq_agent_provers config in
  check "original shortcut preserved" (Mstr.find "coq" (get_prover_shortcuts config) = base.prover);
  check "agent shortcut" (Mstr.find "coq-agent" (get_prover_shortcuts config) = companion base);
  check "configuration expansion idempotent"
    (get_provers (add_coq_agent_provers config) = get_provers config);
  let custom_shortcuts = Mstr.add "coq-agent" base.prover (get_prover_shortcuts config) in
  let custom = set_prover_shortcuts config custom_shortcuts |> add_coq_agent_provers in
  check "user-defined agent shortcut preserved"
    (Mstr.find "coq-agent" (get_prover_shortcuts custom) = base.prover);
  let empty = add_coq_agent_provers (default_config "") in
  check "no companion without Coq" (Mprover.is_empty (get_provers empty));

  with_directory (fun dir ->
    let config_file = Filename.concat dir "why3.conf" in
    let agent_settings = Option.get agent.agent in
    let agent = {agent with agent = Some {agent_settings with
      profile = Some "proof"}} in
    let config = set_provers config (Mprover.add agent.prover agent (get_provers config)) in
    let channel = open_out config_file in
    Rc.to_channel channel (rc_of_config config);
    close_out channel;
    let reloaded = read_config (Some config_file) in
    let loaded = get_prover_config reloaded agent.prover in
    check "agent association round trip"
      (match loaded.agent with Some a ->
        a.base_prover = base.prover && a.profile = Some "proof"
       | _ -> false);
    check "original compatibility" ((get_prover_config reloaded base.prover).agent = None);
    let obsolete_file = Filename.concat dir "obsolete.conf" in
    let rc = rc_of_config config in
    let rc = Rc.set_simple_family rc "prover"
        (List.map (fun section -> Rc.set_string section "agent_config" "settings.json")
           (Rc.get_simple_family rc "prover")) in
    let channel = open_out obsolete_file in
    Rc.to_channel channel rc;
    close_out channel;
    check "obsolete per-prover JSON settings rejected"
      (try ignore (read_config (Some obsolete_file)); false
       with ConfigFailure (_, message) ->
         try ignore (Re.Str.search_forward (Re.Str.regexp_string "no longer supported") message 0); true
         with Not_found -> false);

    let data_file = Filename.concat dir "detection.conf" in
    let support = Filename.concat dir "support-version" in
    write support "8.20.1\n";
    write data_file (Printf.sprintf
      "[ITP coq]\nname = \"Coq\"\nexec = \"coqtop\"\nsupport_library = \"%s\"\nversion_ok = \"8.20.1\"\nversion_bad = \"8.15.0\"\ncommand = \"%%e -batch -l %%f\"\ndriver = \"coq\"\n"
      support);
    let data = Autodetection.Prover_autodetection_data.from_file data_file in
    let partial version path = Autodetection.Partial.{
      name = "Coq"; version; path; shortcut = None; manual = true} in
    let detect binaries =
      Autodetection.compute_builtin_prover binaries (default_config "") data in
    check "supported detected version paired"
      (Mprover.cardinal (detect [partial "8.20.1" "/one/coqtop"]) = 2);
    check "multiple detected installations paired"
      (Mprover.cardinal (detect [partial "8.20.1" "/one/coqtop";
                                partial "8.20.1" "/two/coqtop"]) = 4);
    check "known bad version rejected"
      (Mprover.is_empty (detect [partial "8.15.0" "/one/coqtop"]));
    write support "9.0.0\n";
    check "incompatible support library rejected"
      (Mprover.is_empty (detect [partial "8.20.1" "/one/coqtop"]));
    write support "8.99.1\n";
    check "usable unknown version paired"
      (Mprover.cardinal (detect [partial "8.99.1" "/one/coqtop"]) = 2);

    (* Full initialization must derive from the effective user configuration,
       and never load agent credentials merely to list provers. *)
    write config_file
      "[main]\nmagic = 14\n[prover]\nname = \"Coq\"\nversion = \"8.20.1\"\ncommand = \"/custom/coqtop -l %f\"\ndriver = \"coq\"\ninteractive = true\nshortcut = \"coq\"\n";
    let initialized = init_config (Some config_file) in
    check "manually configured Coq paired" (Mprover.cardinal (get_provers initialized) = 2);
    Mstr.iter (fun _ strategy ->
      let has_agent =
        let text = strategy.strategy_code in
        let rec find i = i + 11 <= String.length text &&
          (String.sub text i 11 = "AI-assisted" || find (i + 1)) in
        find 0
      in
      check "agent excluded from automatic strategies" (not has_agent))
      (get_strategies initialized);
    let extra_file = Filename.concat dir "extra.conf" in
    write extra_file
      "[prover_modifiers]\nname = \"Coq\"\nversion = \"8.20.1\"\nalternative = \"\"\noption = \"-custom-option\"\n";
    let initialized = init_config ~extra_config:[extra_file] (Some config_file) in
    let original = get_prover_config initialized base.prover in
    let derived = get_prover_config initialized (companion base) in
    check "user modifiers inherited by derived companion"
      (original.extra_options = derived.extra_options &&
       List.mem "-custom-option" derived.extra_options));
  print_endline "Coq agent detection tests passed"
