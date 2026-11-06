(********************************************************************)
(* The Why3 Verification Platform / The Why3 Development Team         *)
(* Copyright 2010-2026 -- Inria - CNRS - Paris-Saclay University        *)
(* Distributed under the GNU LGPL version 2.1, with the exception      *)
(* described in the file LICENSE.                                    *)
(********************************************************************)

open Session_itp

let prepare ~mode ~session ~driver ?file goal prover = match mode with
  | Coq_agent.Generate ->
      let _, filename, _ = Session_script.prepare ~session ~driver ?file
          ~keep_existing:true goal prover in
      filename
  | Coq_agent.Check ->
      (* Replay must not create, relocate, or rewrite files. *)
      let attempt = Session_script.register ~session ~driver ?file goal prover in
      let path = Option.get (get_proof_attempt_node session attempt).proof_script in
      Sysutil.system_dependent_absolute_path (get_dir session) path

let guard ~session ~current_session ~goal ~attempt ~prover =
  let original_attempt = get_proof_attempt_node session attempt in
  let original_task = try Some (get_task session goal) with Not_found -> None in
  let source_fingerprint () =
    let file = get_encapsulating_file session (APn goal) in
    let filename = Sysutil.system_dependent_absolute_path (get_dir session) (file_path file) in
    if Sys.file_exists filename then Some (Digest.file filename) else None in
  let original_source = source_fingerprint () in
  fun () ->
    try current_session () == session &&
      source_fingerprint () = original_source &&
      get_proof_attempt_node session attempt == original_attempt &&
      (match original_task with Some task -> get_task session goal == task | None -> false) &&
      Whyconf.Hprover.find (get_proof_attempt_ids session goal) prover = attempt
    with Not_found | BadID | Sys_error _ -> false
