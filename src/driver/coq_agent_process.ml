(********************************************************************)
(* The Why3 Verification Platform / The Why3 Development Team         *)
(* Copyright 2010-2026 -- Inria - CNRS - Paris-Saclay University        *)
(* Distributed under the GNU LGPL version 2.1, with the exception      *)
(* described in the file LICENSE.                                    *)
(********************************************************************)

type result = { status : Unix.process_status; output : string; timed_out : bool }

let read_file filename =
  let channel = open_in_bin filename in
  Fun.protect ~finally:(fun () -> close_in_noerr channel) (fun () ->
    really_input_string channel (in_channel_length channel))

let write_file filename text =
  let fd = Unix.openfile filename [Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC] 0o600 in
  let channel = Unix.out_channel_of_descr fd in
  Fun.protect ~finally:(fun () -> close_out_noerr channel) (fun () ->
    output_string channel text; flush channel)

let directory prefix =
  let path = Filename.temp_file prefix "" in
  Sys.remove path;
  Unix.mkdir path 0o700;
  path

let find_executable command =
  let usable path =
    try Unix.access path [Unix.X_OK]; not (Sys.is_directory path)
    with Unix.Unix_error _ | Sys_error _ -> false in
  let path =
    if Filename.basename command <> command then command
    else
      let paths = String.split_on_char (if Sys.win32 then ';' else ':')
          (Option.value ~default:"" (Sys.getenv_opt "PATH")) in
      match List.find_opt (fun dir -> usable (Filename.concat dir command)) paths with
      | Some dir -> Filename.concat dir command
      | None -> raise (Coq_agent_config.Error ("Executable not found: " ^ command))
  in
  if not (usable path) then
    raise (Coq_agent_config.Error ("Executable not available: " ^ command));
  Sysutil.concat (Sys.getcwd ()) path

let sleep seconds = ignore (Unix.select [] [] [] seconds)
let succeeds r = not r.timed_out && r.status = Unix.WEXITED 0

let run ?env ?stdin ~cwd ~timeout arguments =
  let env = Option.value ~default:(Unix.environment ()) env in
  let executable = match arguments with
    | command :: _ -> find_executable command
    | [] -> invalid_arg "empty Coq agent subprocess" in
  let log = Filename.temp_file ~temp_dir:cwd "process-" ".log" in
  let input = match stdin with
    | Some text ->
        let filename = Filename.temp_file ~temp_dir:cwd "input-" ".txt" in
        write_file filename text;
        filename
    | None -> if Sys.win32 then "NUL" else "/dev/null" in
  let fd_in = Unix.openfile input [Unix.O_RDONLY] 0 in
  let fd_out = Unix.openfile log [Unix.O_WRONLY; Unix.O_TRUNC] 0o600 in
  flush_all ();
  let pid = match Unix.fork () with
    | 0 ->
        (try
           Unix.dup2 fd_in Unix.stdin;
           Unix.dup2 fd_out Unix.stdout;
           Unix.dup2 fd_out Unix.stderr;
           Unix.close fd_in; Unix.close fd_out;
           Unix.chdir cwd;
           Unix.execve executable (Array.of_list arguments) env
         with _ -> Unix._exit 127)
    | pid -> pid in
  Unix.close fd_in; Unix.close fd_out;
  let deadline = Unix.gettimeofday () +. max 0.01 timeout in
  let rec wait () =
    match Unix.waitpid [Unix.WNOHANG] pid with
    | 0, _ when Unix.gettimeofday () < deadline -> sleep 0.02; wait ()
    | 0, _ ->
        (try Unix.kill pid Sys.sigkill with Unix.Unix_error _ -> ());
        let _, status = Unix.waitpid [] pid in status, true
    | _, status -> status, false in
  let status, timed_out = wait () in
  let output = read_file log in
  Sys.remove log;
  if stdin <> None then Sys.remove input;
  { status; output; timed_out }
