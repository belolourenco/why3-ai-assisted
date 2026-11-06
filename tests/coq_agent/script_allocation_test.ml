open Why3
module P = Coq_agent_process

(* Exercise IDE scheduling without ever starting Coq or an agent. *)
module Scheduler = struct
  let blocking = false
  let multiplier = 1
  let timeout ~ms:_ _ = ()
  let idle ~prio:_ _ = ()
end
module Controller = Controller_itp.Make(Scheduler)

let check message condition = if not condition then failwith message

let () =
  let root = Sysutil.concat (Sys.getcwd ()) "../.." in
  let directory = P.directory "why3-agent-script-allocation-" in
  let config = Whyconf.default_config "" in
  let main = Whyconf.get_main config
    |> fun m -> Whyconf.set_libdir m (Filename.concat root "lib")
    |> fun m -> Whyconf.set_datadir m root in
  let base = Whyconf.{
    prover = {prover_name="Coq";prover_version="test";prover_altern=""};
    command="coqtop -batch -R %l/coq Why3 -l %f";
    command_steps=None;driver=None,"coq";in_place=false;editor="";interactive=true;
    agent=None;extra_options=[];extra_drivers=[]} in
  let provers = Whyconf.coq_agent_provers (Whyconf.Mprover.singleton base.Whyconf.prover base) in
  let prover = Whyconf.{base.prover with prover_altern="AI-assisted"} in
  let config = Whyconf.set_main config main |> fun config -> Whyconf.set_provers config provers in
  let env = Env.create_env [Filename.concat root "stdlib"] in
  let session = Session_itp.empty_session directory in
  let controller = Controller_itp.create_controller config env session in
  let input = Filename.concat directory "bigInt.mlw" in
  P.write_file input (P.read_file (Filename.concat root "examples_in_progress/bigInt.mlw"));
  Controller_itp.add_file controller input;
  let file = Session_itp.find_file_from_path session (Sysutil.relativize_filename directory input) in
  let theory = List.find (fun t -> (Session_itp.theory_name t).Ident.id_string = "N")
      (Session_itp.file_theories file) in
  let goal = List.find (fun g -> (Session_itp.get_proof_name session g).Ident.id_string = "add_array'vc")
      (Session_itp.theory_goals theory) in
  let tasks = Session_itp.apply_trans_to_goal ~allow_no_effect:false session env "split_vc" [] goal in
  let tid = Session_itp.graft_transf session goal "split_vc" [] tasks in
  let children = Session_itp.get_sub_tasks session tid in
  check "real bigInt regression has many split goals" (List.length children > 10);
  let script_of goal =
    let id = Whyconf.Hprover.find (Session_itp.get_proof_attempt_ids session goal) prover in
    let pa = Session_itp.get_proof_attempt_node session id in
    Sysutil.system_dependent_absolute_path directory (Option.get pa.Session_itp.proof_script) in
  let queue_children () =
    List.iter (fun goal -> Controller.schedule_proof_attempt ~agent_mode:Coq_agent.Generate
      controller goal prover ~limits:Call_provers.empty_limits ~notification:(fun _ -> ())
      ~callback:(fun _ _ -> ())) children;
    let scripts = List.map script_of children in
    check "all bigInt split script paths are distinct"
      (List.length (List.sort_uniq String.compare scripts) = List.length children);
    check "all bigInt split scripts exist before execution" (List.for_all Sys.file_exists scripts);
    Controller.interrupt controller in
  queue_children ();
  (* Recreate the old parent/child aliases while retaining the parent's file. *)
  let shared = script_of (List.hd children) in
  let shared_source = P.read_file shared in
  let shared_path = Sysutil.relativize_filename directory shared in
  List.iter (fun goal -> ignore (Session_itp.graft_proof_attempt ~file:shared_path session goal
    prover ~limits:Call_provers.empty_limits)) [goal; List.nth children 1];
  queue_children ();
  check "legacy parent retains its source and path"
    (script_of goal = shared && P.read_file shared = shared_source);
  check "children no longer share the parent's script"
    (List.for_all (fun child -> script_of child <> shared) children);
  (* A missing file still belongs to its registered parent, and cannot be
     appropriated when a colliding child is repaired. *)
  Sys.remove shared;
  ignore (Session_itp.graft_proof_attempt ~file:shared_path session (List.hd children)
    prover ~limits:Call_provers.empty_limits);
  queue_children ();
  check "missing parent script remains reserved"
    (not (Sys.file_exists shared) &&
     List.for_all (fun child -> script_of child <> shared) children);
  let requested = Filename.concat directory "requested.v" in
  Controller.schedule_proof_attempt ~agent_mode:Coq_agent.Generate ~proof_script_filename:requested
    controller (List.hd children) prover ~limits:Call_provers.empty_limits
    ~notification:(fun _ -> ()) ~callback:(fun _ _ -> ());
  check "explicit script path honored when updating an existing attempt"
    (script_of (List.hd children) = requested && Sys.file_exists requested);
  Controller.interrupt controller;
  let child = List.hd children in
  let attempt = Whyconf.Hprover.find (Session_itp.get_proof_attempt_ids session child) prover in
  let current = ref session in
  let guard = Coq_agent_session.guard ~session ~current_session:(fun () -> !current)
      ~goal:child ~attempt ~prover in
  check "current session guard accepts unchanged goal" (guard ());
  let source = P.read_file input in
  P.write_file input (source ^ "\n");
  check "source change invalidates publication" (not (guard ()));
  P.write_file input source;
  current := Session_itp.empty_session directory;
  check "session replacement invalidates publication" (not (guard ()));
  current := session;
  ignore (Session_itp.graft_proof_attempt session child prover ~limits:Call_provers.empty_limits);
  check "superseded attempt invalidates publication" (not (guard ()));
  Printf.printf "bigInt script allocation passed for %d split goals without model calls\n" (List.length children)
