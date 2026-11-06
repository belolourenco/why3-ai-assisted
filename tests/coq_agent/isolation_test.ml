open Why3
module P = Coq_agent_process

(* Opt-in platform probe: no model calls or real credentials. Use the installed
   Codex sandbox helper, which is normally a CLI argv[0]-dispatch symlink. *)
let () = match Sys.getenv_opt "WHY3_CODEX_SANDBOX" with
  | None -> print_endline "SKIP: set WHY3_CODEX_SANDBOX to test the installed sandbox helper"
  | Some executable ->
      let executable = P.find_executable executable in
      let directory = P.directory "why3-agent-isolation-test-" in
      let work = Filename.concat directory "work" in
      Unix.mkdir work 0o700;
      let canary = Filename.concat directory "protected-input" in
      let outside = Filename.concat directory "outside-write" in
      let permitted = Filename.concat work "permitted" in
      P.write_file canary "test-only-no-credentials";
      let probe = Filename.concat work "probe.sh" in
      P.write_file probe (Printf.sprintf
        "#!/bin/sh\nif cat %s; then exit 55; fi\ntouch %s\ntouch %s\n"
        (Filename.quote canary) (Filename.quote outside) (Filename.quote permitted));
      let open Json_base in
      let entry path access = Record ["path", path; "access", String access] in
      let path name = Record ["type",String "path"; "path",String name] in
      let minimal = Record ["type",String "special"; "value",Record ["kind",String "minimal"]] in
      let profile = Record ["type",String "managed";
        "file_system",Record ["type",String "restricted";"entries",List [
          entry minimal "read";
          entry (path (Filename.dirname executable)) "read";
          entry (path (Filename.dirname (Unix.realpath executable))) "read";
          entry (path work) "write"]];
        "network",String "restricted"] in
      let result = P.run ~cwd:work ~timeout:20. [executable;
        "--sandbox-policy-cwd";work;"--command-cwd";work;
        "--permission-profile";Format.asprintf "%a" print_json profile;
        "--";"/bin/sh";probe] in
      if not (P.succeeds result) || Sys.file_exists outside || not (Sys.file_exists permitted) ||
         P.read_file canary <> "test-only-no-credentials" then
        failwith ("Sandbox isolation probe failed: " ^ result.P.output);
      print_endline "Coq agent sandbox isolation probe passed"
