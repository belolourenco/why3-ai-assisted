(********************************************************************)
(* The Why3 Verification Platform / The Why3 Development Team         *)
(* Copyright 2010-2026 -- Inria - CNRS - Paris-Saclay University        *)
(* Distributed under the GNU LGPL version 2.1, with the exception      *)
(* described in the file LICENSE.                                    *)
(********************************************************************)

open Wstdlib
open Session_itp

let script_path session path =
  Sysutil.system_dependent_absolute_path (get_dir session) path

let script_key path =
  let path = Sysutil.concat (Sys.getcwd ()) path in
  try Unix.realpath path with Unix.Unix_error _ -> path

let create_file_rel_path ~session ~driver pn =
  let task = get_task session pn in
  let session_dir = get_dir session in
  let th = get_encapsulating_theory session (APn pn) in
  let th_name = (theory_name th).Ident.id_string in
  let f = get_encapsulating_file session (ATh th) in
  let fn = Filename.chop_extension (Sysutil.basename (file_path f)) in
  let file = Driver.file_of_task driver fn th_name task in
  let reserved = ref Sstr.empty in
  session_iter_proof_attempt (fun _ pa ->
    Option.iter (fun path -> reserved := Sstr.add (script_key (script_path session path)) !reserved)
      pa.proof_script) session;
  let file = Sysutil.uniquify ~reserved:(fun path -> Sstr.mem (script_key path) !reserved)
      (Filename.concat session_dir file) in
  Sysutil.relativize_filename session_dir file

let register ~session ~driver ?file pn pr =
  try
    let panid = Whyconf.Hprover.find (get_proof_attempt_ids session pn) pr in
    let pa = get_proof_attempt_node session panid in
    if pa.proof_script = None then begin
      let file = match file with Some file -> file | None -> create_file_rel_path ~session ~driver pn in
      set_proof_script pa file
    end;
    panid
  with Not_found ->
    let file = match file with Some file -> file | None -> create_file_rel_path ~session ~driver pn in
    graft_proof_attempt session pn pr ~file ~limits:Call_provers.empty_limits

let prepare ~session ~driver ?file ~keep_existing pn pr =
  let panid = register ~session ~driver ?file pn pr in
  let pa = get_proof_attempt_node session panid in
  let old_res = pa.proof_state in
  let file = script_path session (Option.get pa.proof_script) in
  let shared = ref false in
  if keep_existing then
    session_iter_proof_attempt (fun other_id other ->
      if other_id <> panid then Option.iter (fun path ->
        if script_key (script_path session path) = script_key file then shared := true)
          other.proof_script) session;
  let panid, file, previous = if !shared then begin
    let path = create_file_rel_path ~session ~driver pn in
    let panid = graft_proof_attempt session pn pr ~file:path ~limits:pa.limits in
    panid, script_path session path, Some file
  end else panid, file, None in
  if not keep_existing || not (Sys.file_exists file) then begin
    let previous = match previous with
      | Some _ -> previous
      | None when Sys.file_exists file ->
          let backup = file ^ ".bak" in
          if Sys.file_exists backup then Sys.remove backup;
          Sys.rename file backup;
          Some backup
      | None -> None in
    let old = Option.bind previous (fun path ->
      if Sys.file_exists path then Some (open_in path) else None) in
    Fun.protect ~finally:(fun () -> Option.iter close_in_noerr old) (fun () ->
      let ch = open_out file in
      Fun.protect ~finally:(fun () -> close_out_noerr ch) (fun () ->
        let fmt = Format.formatter_of_out_channel ch in
        Driver.print_task ?old driver fmt (get_task session pn);
        Format.pp_print_flush fmt ()))
  end;
  panid, file, old_res
