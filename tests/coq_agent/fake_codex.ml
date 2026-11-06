open Why3
module P = Coq_agent_process

let () =
  let args = Array.to_list Sys.argv |> List.tl in
  if List.mem "--version" args then print_endline "codex-cli 0.163.0"
  else if List.mem "--help" args then
    print_endline "--json --strict-config --model --cd --skip-git-repo-check --ephemeral --ignore-user-config --ignore-rules"
  else if args = ["login"; "status"] then
    print_endline (Option.value ~default:"Logged in using ChatGPT" (Sys.getenv_opt "WHY3_FAKE_LOGIN"))
  else begin
    ignore (Sysutil.channel_contents stdin);
    let rec model = function "--model" :: value :: _ -> value | _ :: rest -> model rest | [] -> "" in
    let model = model args in
    P.write_file "arguments.txt" (String.concat "\n" args);
    let count = if Sys.file_exists "invocations" then int_of_string (P.read_file "invocations") else 0 in
    P.write_file "invocations" (string_of_int (count+1));
    if model = "fake-timeout" then Unix.sleep 5;
    if model = "fake-fail" then begin
      if Sys.getenv_opt "WHY3_TEST_API_AUTH" <> None then failwith "key source leaked into backend environment";
      print_endline (Option.value ~default:"fake error" (Sys.getenv_opt "CODEX_API_KEY")); exit 1
    end;
    if Sys.getenv_opt "OPENAI_API_KEY" <> None then failwith "Unexpected inherited OPENAI_API_KEY";
    let source = P.read_file "candidate.v" in
    let marker = Re.Str.regexp_string "(* Why3 goal *)" in
    let offset = Re.Str.search_forward marker source 0 in
    let ending = Re.Str.search_forward (Re.Str.regexp "Proof\\.\\|Admitted\\.") source offset in
    let proof = if model = "fake-admit" || model = "fake-retry" && count = 0 then "Admitted."
      else if model = "fake-abort" then "Proof. Abort." else "Proof. trivial. Qed." in
    P.write_file "candidate.v" (String.sub source 0 ending ^ proof ^ "\n");
    print_endline "{\"type\":\"turn.completed\",\"usage\":{\"input_tokens\":10,\"output_tokens\":5}}"
  end
