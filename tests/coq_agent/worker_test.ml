open Why3
module CP = Call_provers

let result = CP.{pr_answer=Valid;pr_status=Unix.WEXITED 0;pr_output="";
  pr_time=0.;pr_steps=0;pr_models=[]}
let check message condition = if not condition then failwith message

let () =
  let config = Whyconf.get_main (Whyconf.default_config "") in
  let finished = ref false in
  let call = CP.call_worker ~timeout:2. ~max_parallel:1
      ~on_finish:(fun r -> finished := true; r) (fun () -> result) in
  check "worker result" ((CP.wait_on_call call).CP.pr_answer = CP.Valid && !finished);
  let call = CP.call_worker ~timeout:0.1 ~max_parallel:1 (fun () -> Unix.sleep 3; result) in
  check "elapsed timeout" ((CP.wait_on_call call).CP.pr_answer = CP.Timeout);
  let call = CP.call_worker ~timeout:5. ~max_parallel:1 (fun () -> Unix.sleep 3; result) in
  ignore (CP.query_call call);
  CP.interrupt_call ~config call;
  check "interruption" (CP.query_call call = CP.ProverInterrupted);
  let pending = CP.call_worker ~timeout:5. ~max_parallel:1 (fun () -> result) in
  CP.interrupt_call ~config pending;
  check "queued cancellation" (CP.query_call pending = CP.ProverInterrupted);
  let lock = Filename.temp_file "why3-agent-worker-lock-" "" in
  Sys.remove lock;
  let exclusive () =
    if Sys.file_exists lock then {result with CP.pr_answer=CP.Failure "concurrency cap exceeded"}
    else begin
      Coq_agent_process.write_file lock "locked";
      Coq_agent_process.sleep 0.1;
      Sys.remove lock;
      result
    end in
  let first = CP.call_worker ~timeout:2. ~max_parallel:1 exclusive in
  let second = CP.call_worker ~timeout:2. ~max_parallel:2 exclusive in
  check "mixed concurrency caps" ((CP.wait_on_call second).CP.pr_answer = CP.Valid &&
    (CP.wait_on_call first).CP.pr_answer = CP.Valid);
  let marker = Filename.temp_file "why3-agent-worker-child-" "" in
  Sys.remove marker;
  let call = CP.call_worker ~timeout:3. ~max_parallel:1 (fun () ->
    (match Unix.fork () with
     | 0 -> Coq_agent_process.sleep 0.5;
         Coq_agent_process.write_file marker "child survived"; Unix._exit 0
     | _ -> Unix.sleep 2);
    result) in
  ignore (CP.query_call call);
  Coq_agent_process.sleep 0.15;
  CP.interrupt_call ~config call;
  Coq_agent_process.sleep 0.5;
  check "interruption kills child processes" (not (Sys.file_exists marker));
  print_endline "Coq agent worker tests passed"
