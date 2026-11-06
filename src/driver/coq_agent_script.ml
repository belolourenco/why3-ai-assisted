(********************************************************************)
(* The Why3 Verification Platform / The Why3 Development Team         *)
(* Copyright 2010-2026 -- Inria - CNRS - Paris-Saclay University        *)
(* Distributed under the GNU LGPL version 2.1, with the exception      *)
(* described in the file LICENSE.                                    *)
(********************************************************************)

exception Rejected of string
let reject message = raise (Rejected message)

type command = { tokens : string list; start : int; stop : int }
type t = { header : string; context : string; commands : command list; goal : string }

let goal t = t.goal
let context t = t.context

let space = function ' ' | '\t' | '\r' | '\n' -> true | _ -> false
let word c = match c with
  | 'a'..'z' | 'A'..'Z' | '0'..'9' | '_' | '\'' -> true
  | c -> Char.code c >= 128

(* This is a lexer and a deliberately small command policy, not a replacement
   Coq parser. Coq parses and checks every accepted sentence afterwards. Strings
   and nested comments cannot introduce sentence boundaries or hidden commands. *)
let commands source =
  let length = String.length source in
  let pair i s = i + 1 < length && String.sub source i 2 = s in
  let rec quoted i =
    if i = length then reject "Unterminated Coq string";
    if pair i "\"\"" then quoted (i + 2)
    else if source.[i] = '"' then i + 1 else quoted (i + 1) in
  let rec comment depth i =
    if i = length then reject "Unterminated Coq comment";
    (* Coq also recognizes strings INSIDE comments. Delimiters in those
       strings do not change comment nesting (cLexer.comment/string). *)
    if source.[i] = '"' then comment depth (quoted (i + 1))
    else if pair i "(*" then comment (depth + 1) (i + 2)
    else if pair i "*)" then if depth = 1 then i + 2 else comment (depth - 1) (i + 2)
    else comment depth (i + 1) in
  let rec identifier i = if i < length && word source.[i] then identifier (i + 1) else i in
  let rec scan i start tokens acc =
    if i = length then
      if tokens = [] then List.rev acc else reject "Unterminated Coq command"
    else if space source.[i] then scan (i + 1) start tokens acc
    else if pair i "(*" then scan (comment 1 (i + 2)) start tokens acc
    else if pair i ".." then reject "Unsupported consecutive dots in Coq source"
    else if source.[i] = '.' && not
        (i > 0 && i + 1 < length && word source.[i-1] && word source.[i+1]) then
      if tokens = [] then reject "Empty Coq command" else
      scan (i + 1) (i + 1) [] ({tokens=List.rev tokens; start; stop=i+1} :: acc)
    else
      let start = if tokens = [] then i else start in
      let stop = if source.[i] = '"' then quoted (i + 1)
        else if word source.[i] then identifier (i + 1) else i + 1 in
      scan stop start (String.sub source i (stop - i) :: tokens) acc in
  scan 0 0 [] []

let create source =
  let rec find acc = function
    | ({tokens="Theorem" :: name :: _; _} as theorem) :: _ ->
        {header=String.sub source 0 theorem.stop;
         context=String.sub source 0 theorem.start;
         commands=List.rev (theorem :: acc); goal=name}
    | command :: rest -> find (command :: acc) rest
    | [] -> reject "The Coq driver did not generate a theorem obligation" in
  find [] (commands source)

let reserved = ["Why3Baseline"; "Why3Input"; "Why3Published"; "Why3Audit"]

let safe_tokens tokens =
  List.iter (fun token ->
    if List.mem token reserved then reject ("Reserved identifier in an agent proof: " ^ token);
    if List.mem token ["admit"; "Admitted"; "Abort"; "give_up";
        "exact_no_check"; "vm_cast_no_check"; "native_cast_no_check"] then
      reject ("Unsupported command or tactic in an agent proof: " ^ token)) tokens

let identifier token = String.length token > 0 &&
  (match token.[0] with '0'..'9' | '\'' -> false | _ -> true) &&
  String.for_all word token

let qualified_names tokens =
  let rec name = function
    | "." :: component :: rest when identifier component -> name rest
    | rest -> rest in
  let rec names count = function
    | [] -> count
    | component :: rest when identifier component -> names (count + 1) (name rest)
    | _ -> reject "Unsupported Coq import syntax" in
  names 0 tokens

let require command =
  let modules = function ("Import" | "Export") :: rest -> rest | rest -> rest in
  match command.tokens with
  | "Require" :: rest ->
      safe_tokens rest;
      if qualified_names (modules rest) = 0 then reject "Empty Coq import";
      true
  | "From" :: rest ->
      safe_tokens rest;
      let rec split namespace = function
        | "Require" :: rest -> List.rev namespace, modules rest
        | token :: rest -> split (token :: namespace) rest
        | [] -> reject "Unsupported Coq From command" in
      let namespace, modules = split [] rest in
      if qualified_names namespace <> 1 || qualified_names modules = 0 then
        reject "Unsupported Coq import syntax";
      true
  | _ -> false

(* Unknown tactic heads and all other vernacular are rejected. This supports a
   portable Ltac1 subset, not arbitrary Coq plugins or tactic declarations.
   Kernel/dependency checks still cover tactics which create admitted facts. *)
let tactics = [
  "abstract"; "absurd"; "apply"; "assumption"; "assert"; "auto";
  "autorewrite"; "autounfold"; "btauto"; "case"; "case_eq"; "cbn"; "cbv";
  "change"; "classical_left"; "classical_right"; "clear"; "clearbody";
  "cofix"; "compute"; "congruence"; "constr_eq"; "constructor";
  "contradict"; "contradiction"; "cut"; "cutrewrite"; "decide";
  "dependent"; "destruct"; "discriminate"; "do"; "double"; "eapply";
  "eassert"; "eassumption"; "eauto"; "ecase"; "econstructor";
  "edestruct"; "eenough"; "eexact"; "eelim"; "eexists"; "eleft";
  "elim"; "enough"; "epose"; "erewrite"; "eright"; "esimpl";
  "especialize"; "esplit"; "etransitivity"; "evar"; "exact";
  "exfalso"; "exists"; "f_equal"; "fail"; "field"; "field_simplify";
  "first"; "firstorder"; "fix"; "fold"; "fourier"; "generalize";
  "guard"; "hnf"; "idtac"; "induction"; "injection"; "instantiate";
  "intro"; "intros"; "intuition"; "inversion"; "inversion_clear";
  "lapply"; "lazy"; "left"; "let"; "lia"; "linearize"; "lra";
  "move"; "native_compute"; "nia"; "now"; "nra"; "nsatz"; "omega";
  "once"; "pattern"; "pose"; "progress"; "psatz"; "red"; "refine";
  "reflexivity"; "remember"; "rename"; "repeat"; "replace"; "revert";
  "rewrite"; "right"; "ring"; "ring_simplify"; "set"; "simpl";
  "simple"; "simplify_eq"; "solve"; "specialize"; "split"; "subst";
  "suffices"; "surgery"; "symmetry"; "tauto"; "transitivity";
  "trivial"; "try"; "tryif"; "typeclasses"; "unfold"; "unify";
  "unshelve"; "vm_compute"; "with_strategy";
]

let rec unfocus = function
  | ("{" | "}" | "-" | "+" | "*" | "(") :: rest -> unfocus rest
  | "all" :: ":" :: rest -> unfocus rest
  | selector :: ":" :: rest when String.length selector > 0 &&
      String.for_all (function '0'..'9' -> true | _ -> false) selector -> unfocus rest
  | tokens -> tokens

let proof_command command =
  safe_tokens command.tokens;
  let tokens = unfocus command.tokens in
  match tokens with
  | ["Qed"] | ["Defined"] -> `End
  | _ when require command -> `Body
  | "Import" :: names ->
      if qualified_names names = 0 then reject "Empty Coq import";
      `Body
  | ["Open"; "Scope"; name] | ["Close"; "Scope"; name] when identifier name -> `Body
  | tactic :: _ when List.mem tactic tactics -> `Body
  | token :: _ -> reject ("Unsupported command or tactic in an agent proof: " ^ token)
  | [] -> reject "Unsupported empty proof sentence"

let prepare t input =
  let rec header imports expected actual = match expected, actual with
    | [], rest -> List.rev imports, rest
    | trusted :: expected, command :: rest when trusted.tokens = command.tokens ->
        header imports expected rest
    | _, command :: rest when require command -> header (command :: imports) expected rest
    | _ -> reject ("The generated Coq context or theorem was changed, or unsupported " ^
        "top-level content was added. Keep generated declarations unchanged; " ^
        "use assert for local helper lemmas inside Proof.") in
  let imports, rest = header [] t.commands (commands input) in
  match rest with
  | {tokens=["Proof"]; stop; _} :: body ->
      let rec closed = function
        | [] -> reject "The agent proof must end with Qed or Defined"
        | command :: rest -> match proof_command command, rest with
          | `End, [] -> ()
          | `End, _ -> reject "Content after the completed agent proof is not permitted"
          | `Body, rest -> closed rest in
      closed body;
      let imports = List.map (fun command ->
        String.sub input command.start (command.stop - command.start)) imports in
      t.header ^ "\nProof." ^
        (if imports = [] then "" else "\n" ^ String.concat "\n" imports ^ "\n") ^
        String.sub input stop (String.length input - stop)
  | _ -> reject "The expected theorem needs a Proof ... Qed (or Defined) block"
