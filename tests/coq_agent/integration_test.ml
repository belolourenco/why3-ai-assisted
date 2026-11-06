open Why3
module P = Coq_agent_process
module C = Coq_agent_config
module A = Coq_agent
module CP = Call_provers

module Scheduler = struct
  let blocking = false
  let multiplier = 1
  let callbacks = Queue.create ()
  let timeout ~ms:_ f = Queue.add f callbacks
  let idle ~prio:_ f = Queue.add f callbacks
  let step () =
    let size = Queue.length callbacks in
    for _ = 1 to size do
      let f = Queue.pop callbacks in
      if f () then Queue.add f callbacks
    done;
    P.sleep 0.02
end
module Controller = Controller_itp.Make(Scheduler)

let check message condition = if not condition then failwith message

let () =
  let root = Sysutil.concat (Sys.getcwd ()) "../.." in
  let executable = try P.find_executable "coqtop" with C.Error _ -> "" in
  if executable = "" then print_endline "SKIP: Coq is not installed" else begin
    let directory = P.directory "why3-agent-integration-test-" in
    let version = P.run ~cwd:directory ~timeout:10. [executable; "-print-version"] in
    let version = List.hd (String.split_on_char ' ' (String.trim version.P.output)) in
    let config = Whyconf.default_config "" in
    let main = Whyconf.get_main config |> fun m -> Whyconf.set_libdir m (Filename.concat root "lib")
      |> fun m -> Whyconf.set_datadir m root in
    let base = Whyconf.{
      prover = {prover_name="Coq";prover_version=version;prover_altern=""};
      command = Filename.quote executable ^ " -batch -R %l/coq Why3 -l %f";
      command_steps=None;driver=None,"coq";in_place=false;editor="";interactive=true;
      agent=None;extra_options=[];extra_drivers=[]} in
    let provers = Whyconf.coq_agent_provers (Whyconf.Mprover.singleton base.Whyconf.prover base) in
    let prover = Whyconf.Mprover.find Whyconf.{base.prover with prover_altern="AI-assisted"} provers in
    let env = Env.create_env [Filename.concat root "stdlib"] in
    let driver = Driver.load_driver_for_prover main env prover in
    let task = Task.add_prop_decl None Decl.Pgoal
        (Decl.create_prsymbol (Ident.id_fresh "target")) Term.t_true in
    let filename = Filename.concat directory "why3.conf" in
    let fake = Filename.concat (Sys.getcwd ()) "fake_codex.exe" in
    let configured = ref (Whyconf.set_main config main) in
    let configure ?(attempts=1) ?(auth="auth = \"chatgpt\"") ?(executable=fake) model =
      P.write_file filename (Printf.sprintf
        "[coq_agent]\n%s\nexecutable = %S\nretain_failed_attempts = false\n[coq_agent_profile proof]\nmodel = %S\nmax_generation_attempts = %d\n"
        auth executable model attempts);
      configured := Whyconf.add_extra_config (Whyconf.set_main config main) filename in
    let script = Filename.concat directory "proof.v" in
    let prove ?(is_current=(fun () -> true)) mode =
      CP.wait_on_call (A.prove_task ~mode ~main:(Whyconf.get_main !configured) ~prover ~driver ~script ~is_current task) in
    configure "fake-valid";
    Unix.putenv "OPENAI_API_KEY" "must-not-use-this";
    let res = prove A.Generate in
    check ("generation: " ^ res.CP.pr_output) (res.CP.pr_answer = CP.Valid);
    check "proof persisted" (Sys.file_exists script);
    let saved = P.read_file script in
    (* Ordinary prover-server execution and local workers must coexist without
       changing normal Coq's result handling or starving either event stream. *)
    let normal = Driver.prove_task ~old:script ~interactive:true
        ~command:(Whyconf.get_complete_command base ~with_steps:false) ~config:main
        ~limits:{CP.empty_limits with CP.limit_time=10.} driver task in
    let local = CP.call_worker ~timeout:5. ~max_parallel:1 (fun () -> P.sleep 0.05; res) in
    let completed = ref [] in
    let deadline = Unix.gettimeofday () +. 15. in
    while List.length !completed < 2 && Unix.gettimeofday () < deadline do
      CP.get_new_results ~blocking:true |> List.iter (fun (call, update) ->
        match update with
        | CP.ProverFinished result when call = normal || call = local ->
            check ("mixed prover/worker result: " ^ result.CP.pr_output) (result.CP.pr_answer = CP.Valid);
            completed := call :: !completed
        | _ -> ())
    done;
    check "both normal prover and worker results delivered" (List.length !completed = 2);
    check "normal Coq checking preserves saved proof" (P.read_file script = saved);
    Prove_client.disconnect ();
    configured := Whyconf.set_main config main;
    Unix.putenv "WHY3_FAKE_LOGIN" "Not logged in";
    let res = prove A.Check in
    check ("offline replay: " ^ res.CP.pr_output) (res.CP.pr_answer = CP.Valid);
    check "replay does not modify proof" (P.read_file script = saved);
    (* Exercise the actual production path, not just the standalone gate. The
       old signature validator accepted this specialization of an arbitrary n. *)
    let attack_input = Filename.concat directory "reset.why" in
    P.write_file attack_input
      "theory ResetAttack\n use int.Int\n constant n: int\n axiom hn: 0 <= n\n goal target: n = 0\nend\n";
    let theories, _ = Env.read_file Env.base_language env attack_input in
    let attack_task = List.hd (Task.split_theory (Wstdlib.Mstr.find "ResetAttack" theories) None None) in
    let attack_source = Format.asprintf "%t" (fun fmt -> Driver.print_task driver fmt attack_task) in
    let attack_source = Re.Str.global_replace (Re.Str.regexp_string "(* Why3 goal *)")
        ("Reset n.\nDefinition n : Z := 0%Z.\n" ^
         "Definition hn : (0 <= n)%Z := Z.le_refl 0.\n\n(* Why3 goal *)") attack_source in
    let attack_source = Re.Str.global_replace (Re.Str.regexp_string "Proof.\n")
        "Proof.\nreflexivity.\n" attack_source in
    let attack_script = Filename.concat directory "reset.v" in
    P.write_file attack_script attack_source;
    let attack = CP.wait_on_call (A.prove_task ~mode:A.Check ~main ~prover ~driver
        ~script:attack_script attack_task) in
    check ("Reset attack rejected by production service: " ^ attack.CP.pr_output)
      (attack.CP.pr_answer <> CP.Valid);
    check "rejected Reset script not modified" (P.read_file attack_script = attack_source);
    let hidden_source = Format.asprintf "%t" (fun fmt -> Driver.print_task driver fmt attack_task) in
    let hidden_source = Re.Str.global_replace (Re.Str.regexp_string "Proof.\n")
        ("Proof.\n(* \"(*\" *) Reset n.\nParameter n : Z.\nAxiom hn : n = 0%Z.\n" ^
         "Theorem target : n = 0%Z.\nProof.\n(* \"*)\" *) exact hn.\n") hidden_source in
    P.write_file attack_script hidden_source;
    let attack = CP.wait_on_call (A.prove_task ~mode:A.Check ~main ~prover ~driver
        ~script:attack_script attack_task) in
    check "comment delimiters cannot hide replacement of an original axiom"
      (attack.CP.pr_answer <> CP.Valid && P.read_file attack_script = hidden_source);
    Unix.putenv "WHY3_FAKE_LOGIN" "Logged in using ChatGPT";
    (* A valid saved proof avoids a model invocation even if Codex is absent. *)
    configure ~executable:"/missing/codex" "fake-valid";
    check "reuse existing checked proof without Codex" ((prove A.Generate).CP.pr_answer = CP.Valid);
    let invalid = Re.Str.global_replace (Re.Str.regexp_string "trivial.") "admit." saved in
    List.iter (fun model ->
      P.write_file script invalid; configure model;
      let res = prove A.Generate in
      check (model ^ " cannot return Valid") (res.CP.pr_answer <> CP.Valid);
      check (model ^ " preserves previous script") (P.read_file script = invalid))
      ["fake-admit"; "fake-abort"];
    P.write_file script invalid; configure ~attempts:2 "fake-retry";
    let retry = prove A.Generate in
    check ("bounded retry repairs candidate: " ^ retry.CP.pr_output) (retry.CP.pr_answer = CP.Valid);
    check "previous script backed up" (P.read_file (script ^ ".bak") = invalid);
    P.write_file script invalid; configure "fake-valid";
    let res = prove ~is_current:(fun () -> false) A.Generate in
    check "stale result rejected" (res.CP.pr_answer <> CP.Valid && P.read_file script = invalid);
    let first = A.prove_task ~mode:A.Generate ~main:(Whyconf.get_main !configured) ~prover ~driver ~script task in
    let second = A.prove_task ~mode:A.Generate ~main:(Whyconf.get_main !configured) ~prover ~driver ~script task in
    let first = CP.wait_on_call first in
    let second = CP.wait_on_call second in
    check "competing attempts do not overwrite one another"
      (first.CP.pr_answer = CP.Valid && second.CP.pr_answer <> CP.Valid);
    P.write_file script invalid;
    Unix.putenv "WHY3_FAKE_LOGIN" "Logged in using API key";
    let res = prove A.Generate in
    check "authentication mismatch rejected" (res.CP.pr_answer <> CP.Valid);
    Unix.putenv "WHY3_FAKE_LOGIN" "Logged in using ChatGPT";
    let missing = Filename.concat directory "missing-proof.v" in
    configured := Whyconf.set_main config main;
    let missing = CP.wait_on_call (A.prove_task ~mode:A.Check ~main ~prover ~driver ~script:missing task) in
    check "missing saved proof does not generate" (missing.CP.pr_answer <> CP.Valid);
    let secret = "test-secret-never-log" in
    Unix.putenv "WHY3_TEST_API_AUTH" secret;
    configure ~auth:"auth = \"api_key\"\napi_key_env = \"WHY3_TEST_API_AUTH\"" "fake-fail";
    let res = prove A.Generate in
    check "environment API key is supplied and redacted"
      (res.CP.pr_answer = CP.Failure "Codex failed" &&
       not (try ignore (Re.Str.search_forward (Re.Str.regexp_string secret) res.CP.pr_output 0);
            true with Not_found -> false));
    configure "fake-valid";
    let config = !configured |> fun config ->
      Whyconf.set_provers config ~shortcuts:Wstdlib.Mstr.empty provers in
    let session = Session_itp.empty_session directory in
    let controller = Controller_itp.create_controller config env session in
    let input = Filename.concat directory "session.why" in
    P.write_file input "theory Smoke\n goal target: true\nend\n";
    Controller_itp.add_file controller input;
    let file = Session_itp.find_file_from_path session
        (Sysutil.relativize_filename directory input) in
    let goal = List.hd (Session_itp.theory_goals (List.hd (Session_itp.file_theories file))) in
    let schedule controller goal mode =
      let completed = ref None in
      Controller.schedule_proof_attempt ~agent_mode:mode controller goal prover.Whyconf.prover
        ~limits:CP.empty_limits ~notification:(fun _ -> ())
        ~callback:(fun _ status -> match status with
          | Controller_itp.Done result -> completed := Some result
          | Controller_itp.InternalFailure exn -> raise exn
          | _ -> ());
      let deadline = Unix.gettimeofday () +. 90. in
      while !completed = None && Unix.gettimeofday () < deadline do Scheduler.step () done;
      match !completed with Some r -> r | None -> failwith "session proof timed out" in
    let res = schedule controller goal A.Generate in
    check ("native-config session generation: " ^ res.CP.pr_output) (res.CP.pr_answer = CP.Valid);
    let pa_id = Whyconf.Hprover.find (Session_itp.get_proof_attempt_ids session goal) prover.Whyconf.prover in
    let pa = Session_itp.get_proof_attempt_node session pa_id in
    check "session script registered" (pa.Session_itp.proof_script <> None);
    let split_input = Filename.concat directory "split.why" in
    P.write_file split_input
      "theory Split\n use int.Int\n goal split_target: forall x y:int. x = x /\\ y = y\nend\n";
    Controller_itp.add_file controller split_input;
    let split_file = Session_itp.find_file_from_path session
        (Sysutil.relativize_filename directory split_input) in
    let split_goal = List.hd (Session_itp.theory_goals
        (List.hd (Session_itp.file_theories split_file))) in
    let tasks = Session_itp.apply_trans_to_goal ~allow_no_effect:false
        session env "split_vc" [] split_goal in
    let tid = Session_itp.graft_transf session split_goal "split_vc" [] tasks in
    let goals = Session_itp.get_sub_tasks session tid in
    check "split regression has multiple children" (List.length goals > 1);
    let script_of goal =
      let id = Whyconf.Hprover.find (Session_itp.get_proof_attempt_ids session goal)
          prover.Whyconf.prover in
      let pa = Session_itp.get_proof_attempt_node session id in
      Sysutil.system_dependent_absolute_path directory (Option.get pa.Session_itp.proof_script) in
    let queue goal =
      let completed = ref None in
      Controller.schedule_proof_attempt ~agent_mode:A.Generate controller goal prover.Whyconf.prover
        ~limits:CP.empty_limits ~notification:(fun _ -> ())
        ~callback:(fun _ status -> match status with
          | Controller_itp.Done result -> completed := Some result
          | Controller_itp.InternalFailure exn -> raise exn
          | _ -> ());
      completed in
    let wait_all completed =
      let deadline = Unix.gettimeofday () +. 90. in
      while List.exists (fun result -> !result = None) completed &&
            Unix.gettimeofday () < deadline do Scheduler.step () done;
      List.iter (fun result -> match !result with
        | Some result -> check ("queued split generation: " ^ result.CP.pr_output)
            (result.CP.pr_answer = CP.Valid)
        | None -> failwith "queued split generation timed out") completed in
    (* Queue all children before the scheduler starts any job, just as clicking
       the prover on the split_vc node in the IDE does. *)
    let completed = List.map queue goals in
    let scripts = List.map script_of goals in
    check "queued split goals have distinct script paths"
      (List.length (List.sort_uniq String.compare scripts) = List.length goals);
    check "new scripts are created before jobs start" (List.for_all Sys.file_exists scripts);
    wait_all completed;
    let saved_scripts = List.map (fun script -> script, P.read_file script) scripts in
    let completed = List.map queue goals in
    List.iter (fun (script, source) ->
      check "scheduling preserves accepted scripts" (P.read_file script = source)) saved_scripts;
    wait_all completed;
    (* Recreate an old session in which two children share an accepted script.
       Retrying one child must detach it without touching the other child's file. *)
    let keeper = List.hd goals in
    let repaired = List.nth goals 1 in
    let shared_script = script_of keeper in
    let shared_source = P.read_file shared_script in
    let shared_metadata = P.read_file (shared_script ^ ".coqagent.json") in
    let shared_path = Sysutil.relativize_filename directory shared_script in
    ignore (Session_itp.graft_proof_attempt ~file:shared_path session repaired
      prover.Whyconf.prover ~limits:CP.empty_limits);
    check "legacy collision fixture shares a script" (script_of repaired = shared_script);
    let completed = queue repaired in
    check "legacy duplicate association repaired before generation"
      (script_of repaired <> shared_script && script_of keeper = shared_script);
    check "shared source preserved during preparation" (P.read_file shared_script = shared_source);
    wait_all [completed];
    check "shared source preserved after publication" (P.read_file shared_script = shared_source);
    check "shared provenance preserved" (P.read_file (shared_script ^ ".coqagent.json") = shared_metadata);
    List.iter (fun goal ->
      check "repaired split proof replays" ((schedule controller goal A.Check).CP.pr_answer = CP.Valid)) goals;
    (* Missing files referenced by older sessions still reserve their names. *)
    let missing_path = Sysutil.relativize_filename directory
        (Filename.concat directory "missing-shared.v") in
    List.iter (fun goal -> ignore (Session_itp.graft_proof_attempt ~file:missing_path
      session goal prover.Whyconf.prover ~limits:CP.empty_limits)) goals;
    let completed = List.map queue goals in
    check "missing shared script associations repaired"
      (script_of keeper <> script_of repaired);
    wait_all completed;
    (* Replay alone must not create a missing script, even through the IDE scheduler. *)
    let absent = Filename.concat directory "offline-missing.v" in
    ignore (Session_itp.graft_proof_attempt ~file:(Sysutil.relativize_filename directory absent)
      session repaired prover.Whyconf.prover ~limits:CP.empty_limits);
    check "missing session proof fails offline replay"
      ((schedule controller repaired A.Check).CP.pr_answer <> CP.Valid);
    check "offline replay creates no script" (not (Sys.file_exists absent));
    check "missing session proof can be regenerated"
      ((schedule controller repaired A.Generate).CP.pr_answer = CP.Valid);
    (* Ordinary Coq editing uses the same preparation helper and must retain
       its original backup and proof-preservation behavior. *)
    let agent_script = script_of keeper in
    let agent_source = P.read_file agent_script in
    let _, manual_script, _ = Controller.prepare_edition controller keeper base.Whyconf.prover
        ~notification:(fun _ -> ()) in
    check "ordinary Coq and agent scripts are distinct" (manual_script <> agent_script);
    P.write_file manual_script agent_source;
    let _, manual_script_again, _ = Controller.prepare_edition controller keeper base.Whyconf.prover
        ~notification:(fun _ -> ()) in
    check "ordinary Coq retains its script association" (manual_script_again = manual_script);
    check "ordinary Coq backup preserved" (P.read_file (manual_script ^ ".bak") = agent_source);
    check "ordinary Coq refresh preserves proof"
      (try ignore (Re.Str.search_forward (Re.Str.regexp_string "trivial.")
          (P.read_file manual_script) 0); true with Not_found -> false);
    check "ordinary editing leaves the agent proof unchanged" (P.read_file agent_script = agent_source);
    Session_itp.save_session session;
    let config = Whyconf.set_main config main in
    let reloaded = Session_itp.load_session directory in
    let controller = Controller_itp.create_controller config env reloaded in
    ignore (Controller_itp.reload_files ~ignore_shapes:false controller);
    let reloaded = controller.Controller_itp.controller_session in
    let file = Session_itp.find_file_from_path reloaded (Sysutil.relativize_filename directory input) in
    let goal = List.hd (Session_itp.theory_goals (List.hd (Session_itp.file_theories file))) in
    let res = schedule controller goal A.Check in
    check ("saved-session offline replay: " ^ res.CP.pr_output) (res.CP.pr_answer = CP.Valid);
    P.write_file input "theory Smoke\n goal target: false\nend\n";
    ignore (Controller_itp.reload_files ~ignore_shapes:false controller);
    let changed = controller.Controller_itp.controller_session in
    let file = Session_itp.find_file_from_path changed (Sysutil.relativize_filename directory input) in
    let goal = List.hd (Session_itp.theory_goals (List.hd (Session_itp.file_theories file))) in
    let res = schedule controller goal A.Check in
    check "changed VC replay cannot reuse a proof of True" (res.CP.pr_answer <> CP.Valid);
    print_endline "Coq agent integration tests passed"
  end
