(********************************************************************)
(* The Why3 Verification Platform / The Why3 Development Team         *)
(* Copyright 2010-2026 -- Inria - CNRS - Paris-Saclay University        *)
(* Distributed under the GNU LGPL version 2.1, with the exception      *)
(* described in the file LICENSE.                                    *)
(********************************************************************)

open Wstdlib
module P = Coq_agent_process
module S = Coq_agent_script

exception Rejected = S.Rejected
let reject message = raise (Rejected message)

type t = {
  directory : string;
  script : S.t;
  original : string list;
  compiler : string list;
  checker : string list;
  limiter : string;
  timeout : float;
  memory : int;
  assumptions : Sstr.t;
  baseline_digest : Digest.t;
  read_paths : string list;
}

let goal t = S.goal t.script
let read_paths t = t.read_paths
let feedback_command t filename =
  t.limiter :: string_of_int (int_of_float (ceil t.timeout)) ::
    string_of_int t.memory :: "-s" :: t.compiler @ [filename]

let contains text part =
  try ignore (Re.Str.search_forward (Re.Str.regexp_string part) text 0); true
  with Not_found -> false

let toolchain main prover =
  let command = Whyconf.get_complete_command {prover with Whyconf.agent = None} ~with_steps:false in
  let subst argument =
    let replace pattern value text =
      Re.Str.global_replace (Re.Str.regexp_string pattern) value text in
    argument |> replace "%l" (Whyconf.libdir main)
      |> replace "%d" (Whyconf.datadir main) in
  let executable, arguments = match List.map subst (Cmdline.cmdline_split command) with
    | executable :: arguments -> P.find_executable executable, arguments
    | [] -> reject "Empty Coq checking command" in
  let basename = Filename.basename executable in
  if not (Strings.has_prefix ~prefix:"coqtop" basename) then
    reject "The agent requires a Coq command invoking coqtop directly";
  let suffix = String.sub basename 6 (String.length basename - 6) in
  let sibling name = P.find_executable (Filename.concat (Filename.dirname executable) (name ^ suffix)) in
  let rec options compile check = function
    | [] -> List.rev compile, List.rev check
    | ("-batch" | "-q") :: rest -> options compile check rest
    | "-l" :: "%f" :: rest -> options compile check rest
    | ("-R" | "-Q" as flag) :: path :: logical :: rest ->
        let path = Sysutil.concat (Sys.getcwd ()) path in
        options (logical :: path :: flag :: compile) (logical :: path :: flag :: check) rest
    | "-coqlib" :: path :: rest ->
        let path = Sysutil.concat (Sys.getcwd ()) path in
        options (path :: "-coqlib" :: compile) (path :: "-coqlib" :: check) rest
    | "-I" :: path :: rest ->
        options (Sysutil.concat (Sys.getcwd ()) path :: "-I" :: compile) check rest
    | "-w" :: value :: rest -> options (value :: "-w" :: compile) check rest
    | ("-impredicative-set" | "-indices-matter" as flag) :: rest ->
        options (flag :: compile) (flag :: check) rest
    | _ -> reject "Unsupported option in the configured Coq checking command" in
  let compile, check = options [] [] arguments in
  let rec absolute = function
    | ("-R" | "-Q" as flag) :: path :: logical :: rest ->
        flag :: Sysutil.concat (Sys.getcwd ()) path :: logical :: absolute rest
    | ("-I" | "-coqlib" as flag) :: path :: rest ->
        flag :: Sysutil.concat (Sys.getcwd ()) path :: absolute rest
    | arg :: rest -> arg :: absolute rest
    | [] -> [] in
  executable :: absolute arguments,
  sibling "coqc" :: "-q" :: compile, sibling "coqchk" :: "-silent" :: "-o" :: check

let summary output =
  let lines = String.split_on_char '\n' output in
  let rec collect active seen axioms = function
    | [] -> if not seen then reject "Coq checker did not report its assumptions" else axioms
    | line :: rest ->
        let line = String.trim line in
        if Strings.has_prefix ~prefix:"* Axioms:" line then
          let value = String.trim (String.sub line 9 (String.length line - 9)) in
          collect true true (if value = "" || value = "<none>" then axioms else Sstr.add value axioms) rest
        else if Strings.has_prefix ~prefix:"* " line then begin
          let known = List.exists (fun prefix -> Strings.has_prefix ~prefix line)
              ["* Theory: Set is "; "* Theory: Rewrite rules are ";
               "* Constants/Inductives relying on type-in-type:";
               "* Constants/Inductives relying on unsafe (co)fixpoints:";
               "* Inductives whose positivity is assumed:"] in
          if not known then reject ("Unsupported Coq checker summary: " ^ line);
          if (contains line "type-in-type" || contains line "unsafe" || contains line "positivity") &&
             not (Strings.has_suffix ~suffix:"<none>" line) then
            reject ("Unsafe Coq declaration: " ^ line);
          if contains line "Rewrite rules are allowed" then reject "Coq rewrite rules are not permitted";
          collect false seen axioms rest
        end else if active && line <> "" then
          collect active seen (Sstr.add line axioms) rest
        else collect active seen axioms rest
  in collect false false Sstr.empty lines

let execute ~directory ~limiter ~timeout ~memory arguments =
  let args = limiter :: string_of_int (int_of_float (ceil timeout)) ::
      string_of_int memory :: "-s" :: arguments in
  (* OCaml 5 reserves minor-heap arenas for many domains by default, which can
     exceed a modest address-space limit before Coq starts. Checks are serial. *)
  let runtime = Option.value ~default:"" (Sys.getenv_opt "OCAMLRUNPARAM") in
  let env = Array.to_list (Unix.environment ())
    |> List.filter (fun s -> not (Strings.has_prefix ~prefix:"OCAMLRUNPARAM=" s))
    |> fun env -> Array.of_list (("OCAMLRUNPARAM=" ^ runtime ^ ",d=1") :: env) in
  let result = P.run ~env ~cwd:directory ~timeout args in
  if not (P.succeeds result) then
    reject ((if result.P.timed_out then "Coq check timed out\n" else "Coq check failed\n") ^ result.P.output);
  result.P.output

let create ~main ~prover ~directory ~source ~timeout ~memory =
  let script = S.create source in
  let original, compiler, checker = toolchain main prover in
  let limiter = P.find_executable (Filename.concat (Whyconf.libdir main) "why3cpulimit") in
  let run = execute ~directory ~limiter ~timeout ~memory in
  let where = P.run ~cwd:directory ~timeout [List.hd compiler; "-where"] in
  if not (P.succeeds where) then reject "Cannot determine Coq's library directory";
  let rec paths = function
    | ("-R" | "-Q") :: path :: _ :: rest -> path :: paths rest
    | ("-I" | "-coqlib") :: path :: rest -> path :: paths rest
    | _ :: rest -> paths rest | [] -> [] in
  let read_paths = limiter :: Filename.dirname (List.hd compiler) ::
      Filename.dirname (String.trim where.P.output) :: paths compiler in
  List.iter (fun path ->
    let path = try Unix.realpath path with Unix.Unix_error _ -> path in
    let prefix = if Strings.has_suffix ~suffix:Filename.dir_sep path then path else path ^ Filename.dir_sep in
    if directory = path || Strings.has_prefix ~prefix (Unix.realpath directory) then
      reject "The private Coq validation directory overlaps a configured library path") (paths compiler);
  (* Explicitly map the private objects, including on older Coq releases. *)
  let private_path = ["-Q"; directory; ""] in
  let checker = checker @ private_path in
  let expected = prover.Whyconf.prover.Whyconf.prover_version in
  if expected = "" then reject "The detected Coq version is missing";
  let expected_version = Re.Str.regexp
      ("\\(^\\|[^A-Za-z0-9_.+-]\\)" ^ Re.Str.quote expected ^ "\\($\\|[^A-Za-z0-9_.+-]\\)") in
  List.iter (fun tool ->
    let version = P.run ~cwd:directory ~timeout [tool; "--version"] in
    let matches = try ignore (Re.Str.search_forward expected_version version.P.output 0); true
      with Not_found -> false in
    if not (P.succeeds version && matches) then
      reject "The Coq compiler/checker version differs from the detected installation")
    [List.hd compiler; List.hd checker];
  (* The baseline only records the existing context's assumptions. There is no
     contract/module type and no available proof (or admission) of the VC. *)
  let baseline = S.context script in
  P.write_file (Filename.concat directory "Why3Baseline.v") baseline;
  ignore (run (compiler @ private_path @ ["Why3Baseline.v"]));
  let assumptions = summary (run (checker @ ["-norec"; "Why3Baseline"])) in
  { directory; script; original; compiler; checker; limiter; timeout; memory; assumptions;
    baseline_digest = Digest.file (Filename.concat directory "Why3Baseline.vo"); read_paths }

let check ?regenerate t ~candidate =
  try
    (* Gate first, then give normal Why3 regeneration only the approved source.
       Freeze the snapshot outside the agent's writable workspace. *)
    let input = S.prepare t.script (P.read_file candidate) in
    let frozen_input = Filename.concat t.directory "Why3Input.v" in
    P.write_file frozen_input input;
    let with_input f =
      let channel = open_in frozen_input in
      Fun.protect ~finally:(fun () -> close_in_noerr channel) (fun () -> f channel) in
    let regenerated = match regenerate with
      | Some regenerate -> with_input regenerate
      | None -> input in
    (* Apply, rather than merely inspect, the final gate: even a preservation
       parser moving an import must not put it before target elaboration. *)
    let published = S.prepare t.script regenerated in
    P.write_file (Filename.concat t.directory "Why3Published.v") published;
    let run = execute ~directory:t.directory ~limiter:t.limiter ~timeout:t.timeout ~memory:t.memory in
    (* Use the configured ordinary Coq checking command unchanged, with only
       its file placeholder replaced. No private baseline is imported, and no
       tactics are replayed in a different declaration context. Run locally in
       the worker rather than sharing the parent's asynchronous prover socket. *)
    let original = List.map (fun arg ->
      if arg = "%f" then Filename.concat t.directory "Why3Published.v" else arg) t.original in
    ignore (run original);
    let compile name =
      (* A command such as Quit may exit zero without producing a fresh object.
         Never let an earlier attempt's .vo stand in for this candidate. *)
      List.iter (fun suffix ->
        let filename = Filename.concat t.directory (name ^ suffix) in
        if Sys.file_exists filename then Sys.remove filename) [".vo"; ".vos"; ".vok"];
      ignore (run (t.compiler @ ["-Q"; t.directory; ""; name ^ ".v"]));
      if not (Sys.file_exists (Filename.concat t.directory (name ^ ".vo"))) then
        reject "Coq exited without producing the expected checked object" in
    compile "Why3Published";
    let audit = "Require Why3Published.\nCheck @Why3Published." ^ goal t ^ ".\n" in
    P.write_file (Filename.concat t.directory "Why3Audit.v") audit;
    compile "Why3Audit";
    (* Inspect the candidate alone, not its union with the baseline: otherwise
       the baseline could hide removal/specialization of an original axiom. *)
    let assumptions = summary (run (t.checker @ ["-norec"; "Why3Published"])) in
    let assumptions = Sstr.fold (fun name acc ->
      let prefix = "Why3Published." in
      let name = if Strings.has_prefix ~prefix name then
          "Why3Baseline." ^ String.sub name (String.length prefix) (String.length name - String.length prefix)
        else name in Sstr.add name acc) assumptions Sstr.empty in
    let additional = Sstr.diff assumptions t.assumptions in
    if not (Sstr.is_empty additional) then
      reject ("The proof introduces assumptions absent from the generated context: " ^
              String.concat ", " (Sstr.elements additional));
    if not (Sstr.subset t.assumptions assumptions) then
      reject "The proof removed or specialized assumptions from the generated context";
    if Digest.file (Filename.concat t.directory "Why3Baseline.vo") <> t.baseline_digest then
      reject "The protected Coq baseline changed during validation";
    Ok published
  with Rejected message -> Error message

let () = Exn_printer.register (fun fmt -> function
  | Rejected message -> Format.pp_print_string fmt message
  | exn -> raise exn)
