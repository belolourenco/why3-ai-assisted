(********************************************************************)
(* The Why3 Verification Platform / The Why3 Development Team         *)
(* Copyright 2010-2026 -- Inria - CNRS - Paris-Saclay University        *)
(* Distributed under the GNU LGPL version 2.1, with the exception      *)
(* described in the file LICENSE.                                    *)
(********************************************************************)

type 'a failure =
  | Timeout of float
  | Work_failed of exn * float
  | Terminated
  | Missing_result
  | Finish_failed of exn * 'a

type 'a update = No_updates | Started | Finished of 'a | Interrupted

type 'a job = {
  work : unit -> 'a;
  finish : 'a -> 'a;
  cancel : unit -> unit;
  result_file : string;
  timeout : float;
  parallel : int;
  mutable pid : int option;
  mutable started : float;
  mutable announced : bool;
}

type 'a t = {
  jobs : (int, 'a job) Hashtbl.t;
  updates : (int, 'a update) Hashtbl.t;
  on_failure : 'a failure -> 'a;
  mutable next_id : int;
}

let create ~on_failure =
  {jobs=Hashtbl.create 7; updates=Hashtbl.create 7; on_failure; next_id=0}

let submit pool ~timeout ~max_parallel ?(on_finish=Fun.id)
    ?(on_interrupt=(fun () -> ())) work =
  if Sys.win32 then failwith "Local workers currently require a Unix host";
  let id = pool.next_id in
  pool.next_id <- id + 1;
  let result_file = Filename.temp_file "why3-worker-result-" ".bin" in
  Hashtbl.add pool.jobs id {work; finish=on_finish; cancel=on_interrupt; result_file;
    timeout; parallel=max 1 max_parallel; pid=None; started=0.; announced=false};
  id

let has_pending pool = Hashtbl.length pool.jobs > 0

let kill job = match job.pid with
  | None -> ()
  | Some pid ->
      (try Unix.kill (-pid) Sys.sigkill with Unix.Unix_error _ ->
        (try Unix.kill pid Sys.sigkill with Unix.Unix_error _ -> ()))

let poll pool =
  let active = ref (Hashtbl.fold (fun _ job n -> if job.pid = None then n else n+1) pool.jobs 0) in
  let ordered = Hashtbl.fold (fun id job acc -> (id,job) :: acc) pool.jobs []
    |> List.sort (fun (a,_) (b,_) -> Int.compare a b) in
  List.iter (fun (_, job) ->
    let cap = Hashtbl.fold (fun _ running cap ->
      if running.pid = None then cap else min cap running.parallel) pool.jobs job.parallel in
    if job.pid = None && !active < cap then begin
      flush_all ();
      let pid = match Unix.fork () with
        | 0 ->
            (try
               ignore (Unix.setsid ());
               let start = Unix.gettimeofday () in
               let result = try job.work () with exn ->
                 pool.on_failure (Work_failed (exn, Unix.gettimeofday () -. start)) in
               let ch = open_out_bin job.result_file in
               Marshal.to_channel ch result [];
               close_out ch;
               Unix._exit 0
             with _ -> Unix._exit 1)
        | pid -> pid in
      job.pid <- Some pid;
      job.started <- Unix.gettimeofday ();
      incr active
    end) ordered;
  List.iter (fun (id, job) -> match job.pid with
    | None -> ()
    | Some _ when not job.announced ->
        job.announced <- true;
        Hashtbl.replace pool.updates id Started
    | Some pid ->
        let timed_out = Unix.gettimeofday () -. job.started >= job.timeout in
        if timed_out then kill job;
        let completed, status = Unix.waitpid (if timed_out then [] else [Unix.WNOHANG]) pid in
        if completed <> 0 then begin
          kill job;
          let result =
            if timed_out then pool.on_failure (Timeout job.timeout)
            else if status <> Unix.WEXITED 0 then pool.on_failure Terminated
            else try
              let ch = open_in_bin job.result_file in
              Fun.protect ~finally:(fun () -> close_in_noerr ch) (fun () -> Marshal.from_channel ch)
            with _ -> pool.on_failure Missing_result in
          Sys.remove job.result_file;
          Hashtbl.remove pool.jobs id;
          let result = try job.finish result with exn -> pool.on_failure (Finish_failed (exn, result)) in
          Hashtbl.replace pool.updates id (Finished result)
        end) ordered

let take_updates pool =
  let updates = Hashtbl.fold (fun id update acc -> (id, update) :: acc) pool.updates [] in
  Hashtbl.clear pool.updates;
  updates

let query pool id =
  poll pool;
  match Hashtbl.find_opt pool.updates id with
  | None -> No_updates
  | Some update -> Hashtbl.remove pool.updates id; update

let interrupt pool id =
  (match Hashtbl.find_opt pool.jobs id with
   | None -> ()
   | Some job ->
       kill job;
       Option.iter (fun pid -> ignore (Unix.waitpid [] pid)) job.pid;
       Sys.remove job.result_file;
       Hashtbl.remove pool.jobs id;
       job.cancel ());
  Hashtbl.replace pool.updates id Interrupted
