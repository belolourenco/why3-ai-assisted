(********************************************************************)
(* The Why3 Verification Platform / The Why3 Development Team         *)
(* Copyright 2010-2026 -- Inria - CNRS - Paris-Saclay University        *)
(* Distributed under the GNU LGPL version 2.1, with the exception      *)
(* described in the file LICENSE.                                    *)
(********************************************************************)

module C = Coq_agent_config
module P = Coq_agent_process
module V = Coq_agent_validation
module CP = Call_provers

type mode = Generate | Check

let fingerprint filename =
  if Sys.file_exists filename then Some (Digest.file filename) else None

let render driver ?old task =
  let buffer = Buffer.create 4096 in
  let fmt = Format.formatter_of_buffer buffer in
  Driver.print_task ?old driver fmt task;
  Format.pp_print_flush fmt ();
  Buffer.contents buffer

let json_file filename value =
  P.write_file filename (Format.asprintf "%a\n" Json_base.print_json value)

(* Remove only this job's private directory, never following symlinks. *)
let rec cleanup path =
  match (Unix.lstat path).Unix.st_kind with
  | Unix.S_DIR -> Array.iter (fun name -> cleanup (Filename.concat path name)) (Sys.readdir path);
      Unix.rmdir path
  | _ -> Sys.remove path

let expire_old_attempts () =
  let root = Filename.get_temp_dir_name () in
  Array.iter (fun name ->
    if Strings.has_prefix ~prefix:"why3-coq-agent-" name then
      let path = Filename.concat root name in
      try
        let stat = Unix.lstat path in
        let marker = Filename.concat path ".retain-until" in
        if stat.Unix.st_kind = Unix.S_DIR && stat.Unix.st_uid = Unix.getuid () &&
           (Unix.lstat marker).Unix.st_kind = Unix.S_REG &&
           float_of_string (P.read_file marker) < Unix.gettimeofday () then cleanup path
      with Sys_error _ | Unix.Unix_error _ | Failure _ -> ()) (Sys.readdir root)

let prove_task ~mode ~main ~prover ~driver ~script ?(is_current=(fun () -> true))
    ?wall_time ?check_memory task =
  let settings = match mode with
    | Check -> None
    | Generate -> Some (Coq_agent_settings.load ~main ?agent:prover.Whyconf.agent ()) in
  let profile = Option.map (fun settings -> snd (C.select_profile settings)) settings in
  if mode = Generate then expire_old_attempts ();
  let timeout, memory, parallel, budget = match settings, profile with
    | Some config, Some profile ->
        float config.C.check_timeout_seconds, config.C.check_memory_mb,
        min config.C.max_parallel_jobs (Whyconf.running_provers_max main),
        float profile.C.wall_time_seconds
    | _ -> 20., 1000, Whyconf.running_provers_max main, 140. in
  let budget = match wall_time with Some t when t > 0. -> min t budget | _ -> budget in
  let memory = match check_memory with Some m when m > 0 -> min m memory | _ -> memory in
  let original = fingerprint script in
  let source = render driver task in
  let candidate_source = match original with
    | None -> source
    | Some _ ->
        let saved = P.read_file script in
        (* Migrate prelude imports into the proof before the ordinary printer
           discards them. Stale/unsupported scripts still follow normal Why3
           regeneration and must pass the gate in the worker. *)
        (try Coq_agent_script.prepare (Coq_agent_script.create source) saved
         with Coq_agent_script.Rejected _ ->
           let ch = open_in script in
           Fun.protect ~finally:(fun () -> close_in_noerr ch)
             (fun () -> render driver ~old:ch task)) in
  let directory = P.directory "why3-coq-agent-" in
  let work = Filename.concat directory "work" in
  let validation = Filename.concat directory "validation" in
  Unix.mkdir work 0o700; Unix.mkdir validation 0o700;
  let candidate = Filename.concat work "candidate.v" in
  let accepted = Filename.concat directory "accepted.v" in
  let accepted_metadata = Filename.concat directory "accepted.json" in
  P.write_file candidate candidate_source;
  let manifest =
    let open Json_base in
    Record (["schema_version", Int 1; "prompt_version", Int 2;
      "validation_policy", String "restricted-script-original-coq-v3";
      "coq_version", String prover.Whyconf.prover.Whyconf.prover_version;
      "mode", String (if mode = Generate then "generate" else "check");
      "source_digest", String (Digest.to_hex (Digest.string source))] @
      match settings, profile with
      | Some config, Some profile -> [
          "auth_mode", String (if config.C.auth = C.Chatgpt then "chatgpt" else "api_key");
          "profile", String config.C.default_profile; "model", String profile.C.model;
          "reasoning_effort", String profile.C.reasoning_effort]
      | _ -> []) in
  json_file (Filename.concat directory "request.json") manifest;
  let result answer output elapsed = CP.{
    pr_answer = answer; pr_status = Unix.WEXITED (if answer = Valid then 0 else 1);
    pr_output = output ^ "\nCoq agent artifacts: " ^ directory;
    pr_time = elapsed; pr_steps = -1; pr_models = [] } in
  let work_job () =
    let start = Unix.gettimeofday () in
    let remaining () = max 0.01 (budget -. (Unix.gettimeofday () -. start)) in
    let finish answer message = result answer message (Unix.gettimeofday () -. start) in
    let reports = ref [] in
    let check_seconds = ref 0. in
    let checked f = let started = Unix.gettimeofday () in
      Fun.protect ~finally:(fun () -> check_seconds := !check_seconds +. Unix.gettimeofday () -. started) f in
    try
      let validator = checked (fun () -> V.create ~main ~prover ~directory:validation ~source
          ~timeout:(min timeout (remaining ())) ~memory) in
      let feedback = String.concat " " (List.map Filename.quote
          (V.feedback_command validator "candidate.v")) in
      let rec attempt count diagnostic =
        if Unix.gettimeofday () -. start >= budget then finish CP.Timeout diagnostic else
        match checked (fun () -> V.check ~regenerate:(fun old -> render driver ~old task)
            validator ~candidate) with
        | Ok source ->
            P.write_file accepted source;
            let open Json_base in
            let fields = match manifest with Record fields -> fields | _ -> assert false in
            json_file accepted_metadata (Record (fields @ [
              "proof_digest", String (Digest.to_hex (Digest.string source));
              "coq_check_seconds", Float !check_seconds;
              "elapsed_seconds", Float (Unix.gettimeofday () -. start);
              "codex_invocations", Int count; "codex_reports", List (List.rev !reports)]));
            finish CP.Valid "Coq proof independently verified"
        | Error diagnostic ->
            P.write_file (Filename.concat directory "validation.log") diagnostic;
            match mode, settings, profile with
            | Generate, Some config, Some profile when count < profile.C.max_generation_attempts ->
                let prompt = Printf.sprintf
                  "Why3 Coq proof task (protocol 2). Complete candidate.v in this directory.\n\
                   Prove the existing theorem %s without changing its statement or generated assumptions.\n\
                   Preserve the Why3 comments and generated declarations. Only edit the Proof ... Qed\n\
                   block. Use only the modules already imported by the generated file. Do not add\n\
                   Require, Import, Export, Include, Load, or other module-loading commands. If a\n\
                   tactic library is unavailable, construct the proof from the existing environment\n\
                   instead of importing it. Use assert for local helper lemmas; top-level lemmas,\n\
                   definitions, notations, custom tactics and\n\
                   context changes are not supported. Do not use Reset, Admitted, admit,\n\
                   Abort, axioms, unchecked casts,\n\
                   unsafe flags, external ML, or files outside this directory. Only edit candidate.v.\n\
                   Use this exact version-matched bounded Coq command for feedback:\n%s\n\
                   Coq uses OCaml: export OCAMLRUNPARAM=d=1 when running it under memory limits.\n\
                   A restricted-script gate precedes ordinary Coq checking; a compiled-result audit\n\
                   checks theorem existence, assumptions and unsafe declarations. Unsupported tactic\n\
                   heads are rejected; prefer ordinary Ltac1 tactics such as intros, assert, destruct,\n\
                   apply, exact, rewrite, auto and lia.\n\
                   Latest validation feedback:\n%s\n"
                  (V.goal validator) feedback diagnostic in
                let report = Coq_agent_codex.generate config profile ~directory:work
                    ~read_paths:(V.read_paths validator)
                    ~timeout:(remaining ()) ~prompt in
                let response = report.Coq_agent_codex.process in
                reports := Json_base.Record ["version", Json_base.String report.Coq_agent_codex.version;
                  "turn_usage", Json_base.List report.Coq_agent_codex.usage] :: !reports;
                if config.C.log_level <> "error" || not (P.succeeds response) then
                  P.write_file (Filename.concat directory (Printf.sprintf "codex-%d.jsonl" (count+1)))
                    response.P.output;
                if response.P.timed_out then finish CP.Timeout "Codex elapsed-time limit exceeded"
                else if not (P.succeeds response) then
                  finish (CP.Failure "Codex failed") response.P.output
                else attempt (count+1) diagnostic
            | _ -> finish (CP.Unknown "Coq proof did not pass independent validation") diagnostic
      in attempt 0 ""
    with exn -> finish (CP.Failure "Coq agent failed")
        (Format.asprintf "%a" Exn_printer.exn_printer exn) in
  let on_finish outcome =
    let outcome = if outcome.CP.pr_answer <> CP.Valid then outcome
      else if not (is_current ()) || fingerprint script <> original then
        {outcome with CP.pr_answer = CP.Unknown "Stale Coq agent result";
          pr_output = "The goal or saved script changed; the generated proof was not published."}
      else begin
        (* The accepted bytes live outside Codex's writable workspace. *)
        let source = P.read_file accepted in
        if mode = Generate then begin
          let parent = Filename.dirname script in
          let temporary = Filename.temp_file ~temp_dir:parent ".why3-coq-agent-" ".v" in
          Fun.protect ~finally:(fun () -> if Sys.file_exists temporary then Sys.remove temporary)
            (fun () ->
              P.write_file temporary source;
              Option.iter (fun _ ->
                let backup = Filename.temp_file ~temp_dir:parent ".why3-coq-agent-backup-" ".v" in
                Fun.protect ~finally:(fun () -> if Sys.file_exists backup then Sys.remove backup)
                  (fun () -> P.write_file backup (P.read_file script);
                    Sys.rename backup (script ^ ".bak"))) original;
              Sys.rename temporary script);
          let sidecar = script ^ ".coqagent.json" in
          let temporary = Filename.temp_file ~temp_dir:parent ".why3-coq-agent-" ".json" in
          Fun.protect ~finally:(fun () -> if Sys.file_exists temporary then Sys.remove temporary)
            (fun () -> P.write_file temporary (P.read_file accepted_metadata);
              Sys.rename temporary sidecar)
        end;
        outcome
      end in
    let retain = match settings with
      | Some config -> config.C.retain_failed_attempts
      | None -> false in
    if outcome.CP.pr_answer = CP.Valid || not retain then begin
      (try cleanup directory with Sys_error _ | Unix.Unix_error _ -> ());
      {outcome with CP.pr_output = outcome.CP.pr_output ^ "\nTemporary artifacts removed."}
    end else begin
      let days = match settings with Some config -> config.C.retention_days | None -> 7 in
      P.write_file (Filename.concat directory ".retain-until")
        (string_of_float (Unix.gettimeofday () +. float days *. 86400.));
      outcome
    end in
  let on_interrupt () =
    ignore (on_finish (result (CP.Unknown "interrupted") "Coq agent interrupted" 0.)) in
  CP.call_worker ~timeout:budget ~max_parallel:parallel ~on_finish ~on_interrupt work_job

