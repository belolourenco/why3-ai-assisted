open Why3

let check message condition = if not condition then failwith message
let failure = function
  | Local_worker.Timeout _ -> -1
  | Local_worker.Work_failed _ -> -2
  | Local_worker.Terminated -> -3
  | Local_worker.Missing_result -> -4
  | Local_worker.Finish_failed (_, result) -> -result

let wait pool id =
  let deadline = Unix.gettimeofday () +. 5. in
  let rec loop () =
    check "generic worker test timed out" (Unix.gettimeofday () < deadline);
    match Local_worker.query pool id with
    | Local_worker.Finished result -> result
    | Local_worker.Interrupted -> failwith "unexpected interruption"
    | Local_worker.No_updates | Local_worker.Started ->
        ignore (Unix.select [] [] [] 0.01); loop () in
  loop ()

let () =
  let pool = Local_worker.create ~on_failure:failure in
  let submit ?on_finish work = Local_worker.submit pool ~timeout:1. ~max_parallel:1 ?on_finish work in
  let parent = Unix.getpid () in
  let finalized = ref false in
  let id = submit ~on_finish:(fun result ->
    check "finalization runs in parent" (Unix.getpid () = parent);
    finalized := true; result + 1) (fun () ->
      check "work runs in child" (Unix.getpid () <> parent); 41) in
  check "generic result needs no prover types" (wait pool id = 42 && !finalized);
  check "work exception mapping" (wait pool (submit (fun () -> failwith "work")) = -2);
  check "finalization exception mapping"
    (wait pool (submit ~on_finish:(fun _ -> failwith "finish") (fun () -> 42)) = -42);
  check "terminated child mapping" (wait pool (submit (fun () -> Unix._exit 1)) = -3);
  check "missing result mapping" (wait pool (submit (fun () -> Unix._exit 0)) = -4);
  let pending = submit (fun () -> 42) in
  Local_worker.interrupt pool pending;
  check "updates delivered" (Local_worker.take_updates pool = [pending, Local_worker.Interrupted]);
  check "updates drained" (Local_worker.take_updates pool = []);
  check "no jobs left" (not (Local_worker.has_pending pool));
  print_endline "Generic local worker tests passed"
