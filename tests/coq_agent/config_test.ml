open Why3
module C = Coq_agent_config
module P = Coq_agent_process

let check message condition = if not condition then failwith message
let contains text part =
  try ignore (Re.Str.search_forward (Re.Str.regexp_string part) text 0); true
  with Not_found -> false

let rejects label f = match f () with
  | _ -> failwith ("expected invalid configuration: " ^ label)
  | exception C.Error message ->
      check ("wrong diagnostic: " ^ message) (contains message label);
      check "secret exposed by diagnostic" (not (contains message "test-secret-do-not-print"))

let directory = P.directory "why3-agent-config-test-"
let filename = Filename.concat directory "why3.conf"
let load text =
  P.write_file filename text;
  C.load_rc [C.rc_source ~filename (Rc.from_file filename)]
let profile = "\n[coq_agent_profile proof]\nmodel = \"test-model\"\n"
let config fields = load ("[coq_agent]\n" ^ fields ^ profile)

let () =
  let c = config "" in
  check "default auth" (c.C.auth = C.Chatgpt);
  check "default executable" (c.C.executable = "codex");
  check "default concurrency" (c.C.max_parallel_jobs = 1);
  check "default checking limits" (c.C.check_timeout_seconds = 20 && c.C.check_memory_mb = 1000);
  check "default logging" (c.C.retention_days = 7 && c.C.retain_failed_attempts);
  let name, p = C.select_profile c in
  check "default profile" (name = "proof" && p.C.model = "test-model");
  check "default search limits" (p.C.wall_time_seconds = 600 && p.C.max_generation_attempts = 2);
  check "default effort" (p.C.reasoning_effort = "high");
  check "default isolation" (c.C.ephemeral && c.C.ignore_user_config && not c.C.shell_network_access);
  check "relative executable resolution"
    ((config "executable = \"tools/codex\"\n").C.executable = Filename.concat directory "tools/codex");
  check "absolute executable" ((config "executable = \"/opt/bin/codex\"\n").C.executable = "/opt/bin/codex");
  check "environment key is not resolved during loading"
    ((config "auth = \"api_key\"\napi_key_env = \"MISSING_TEST_KEY\"\n").C.auth =
     C.Api_key (C.Environment "MISSING_TEST_KEY"));
  let c = config ("default_profile = \"quick\"\n[coq_agent_profile quick]\n" ^
    "model = \"quick-model\"\nreasoning_effort = \"medium\"\nwall_time_seconds = 120\nmax_generation_attempts = 1\n") in
  check "named profile" (fst (C.select_profile c) = "quick");
  check "explicit profile" (fst (C.select_profile ~name:"proof" c) = "proof");
  rejects "profile" (fun () -> C.select_profile ~name:"missing" c);
  List.iter (fun (field, diagnostic) -> rejects diagnostic (fun () -> config field)) [
    "typo = 1\n", "not supported";
    "schema_version = 1\nschema_version = 1\n", "must occur once";
    "schema_version = 2\n", "schema_version";
    "backend = \"unknown\"\n", "backend";
    "auth = \"auto\"\n", "unsupported";
    "api_key = \"test-secret-do-not-print\"\n", "cannot be stored";
    "api_key_env = \"KEY\"\n", "chatgpt mode";
    "auth = \"api_key\"\n", "requires api_key_env";
    "auth = \"api_key\"\napi_key_env = \"1-BAD\"\n", "environment variable name";
    "max_parallel_jobs = 0\n", "positive integer";
    "sandbox = \"danger-full-access\"\n", "unsupported";
    "approval_policy = \"on-request\"\n", "unsupported";
    "ignore_user_config = false\n", "must be true";
    "check_memory_mb = \"wrong-type\"\n", "expected value type";
  ];
  List.iter (fun field -> rejects "positive integer" (fun () -> config (field ^ " = -1\n")))
    ["check_timeout_seconds"; "check_memory_mb"; "retention_days"];
  rejects "profiles" (fun () -> load "[coq_agent]\nauth = \"chatgpt\"\n");
  rejects "Why3 configuration" (fun () -> C.load_rc []);
  rejects "placeholder" (fun () -> load "[coq_agent_profile proof]\nmodel = \"REPLACE_WITH_YOUR_MODEL_ID\"\n");
  rejects "nonempty" (fun () -> load "[coq_agent_profile proof]\nmodel = \"\"\n");
  List.iter (fun field -> rejects "positive integer" (fun () ->
    load (profile ^ field ^ " = 0\n"))) ["wall_time_seconds"; "max_generation_attempts"];
  rejects "unsupported" (fun () -> load (profile ^ "reasoning_effort = \"bogus\"\n"));
  let example = "../../share/coqagent.conf.example" in
  let rc = Rc.from_file example in
  rejects "placeholder" (fun () -> C.load_rc [C.rc_source ~filename:example rc]);
  let rc = Rc.set_family rc "coq_agent_profile"
      (List.map (fun (name, section) -> name, Rc.set_string section "model" "example-test-model")
         (Rc.get_family rc "coq_agent_profile")) in
  check "distributed example loads after setup"
    ((C.load_rc [C.rc_source ~filename:example rc]).C.auth = C.Chatgpt);
  print_endline "Coq agent configuration tests passed"
