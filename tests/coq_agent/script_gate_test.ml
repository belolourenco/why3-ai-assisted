open Why3
module S = Coq_agent_script

let context = "(* generated *)\nRequire Import BuiltIn.\nParameter n : Z.\nAxiom hn : (0 <= n)%Z.\n"
let header = context ^ "(* Why3 goal *)\nTheorem target : n = 0%Z."
let source = header ^ "\nProof.\n\nQed.\n"
let gate = S.create source
let proof body = header ^ "\nProof.\n" ^ body ^ "\nQed.\n"
let contains text part =
  try ignore (Re.Str.search_forward (Re.Str.regexp_string part) text 0); true
  with Not_found -> false

let test name expected candidate =
  let result = try Ok (S.prepare gate candidate) with S.Rejected e -> Error e in
  if Result.is_ok result <> expected then failwith (name ^ ": " ^
    match result with Ok _ -> "unexpectedly accepted" | Error e -> e);
  match result with
  | Ok prepared ->
      if S.prepare gate prepared <> prepared then failwith (name ^ ": gate is not idempotent");
      prepared
  | Error _ -> ""

let () =
  ignore (test "ordinary proof" true (proof "pose proof hn. lia."));
  ignore (test "local helper fact" true
    (proof "assert (helper : n = n) by reflexivity. exact helper."));
  ignore (test "nested comments and strings are not commands" true
    (proof "(* Reset (* nested *) n. Admitted. *) idtac \"Reset n.\"\"Admitted.\". reflexivity."));
  ignore (test "quoted comment delimiters stay inside comments" true
    (proof "(* \"(*\" \"*)\" *) reflexivity."));
  ignore (test "quoted comment delimiters cannot hide commands" false
    (proof ("(* \"(*\" *) Reset n.\nParameter n : Z.\nAxiom hn : n = 0%Z.\n" ^
            "Theorem target : n = 0%Z.\nProof.\n(* \"*)\" *) exact hn.")));
  ignore (test "bullets, braces and selectors" true
    (proof "split.\n- { reflexivity. }\n- all: (try reflexivity)."));
  ignore (test "adjacent brace and sentence boundary" true
    (proof "{ reflexivity.}"));
  let imported = test "additional imports" true
    ("From Coq Require Import Lia.\n" ^ context ^
     "Require (* comment *) Import\n ZArith.\n" ^
     "(* Why3 goal *)\nTheorem target : n = 0%Z.\nProof.\nreflexivity.\nQed.\n") in
  if not (Strings.has_prefix ~prefix:(header ^ "\nProof.") imported) ||
     not (contains imported "From Coq Require Import Lia.") then
    failwith "imports must follow the immutable theorem declaration";
  ignore (test "Reset context specialization" false
    (context ^ "Reset n.\nDefinition n : Z := 0%Z.\n" ^
     "Definition hn : (0 <= n)%Z := Z.le_refl 0.\n" ^
     "Theorem target : n = 0%Z.\nProof. reflexivity. Qed.\n"));
  ignore (test "changed target" false
    (context ^ "Theorem target : True.\nProof. exact I. Qed.\n"));
  ignore (test "changed parameter" false
    ("Require Import BuiltIn.\nDefinition n : Z := 0%Z.\n" ^
     "Axiom hn : (0 <= n)%Z.\nTheorem target : n = 0%Z.\nProof. reflexivity. Qed.\n"));
  ignore (test "top-level helper" false
    (context ^ "Lemma helper : True. Proof. exact I. Qed.\n" ^
     "Theorem target : n = 0%Z.\nProof. reflexivity. Qed.\n"));
  ignore (test "admitted target" false (header ^ "\nAdmitted.\n"));
  List.iter (fun command -> ignore (test command false (proof command))) [
    "Reset n."; "Reset Initial."; "Back 1."; "BackTo 0.";
    "Unset Guard Checking."; "Unset Universe Checking.";
    "#[local] Unset Positivity Checking."; "Set Nested Proofs Allowed.";
    "Axiom bad : False."; "Parameter bad : False."; "Variable bad : False.";
    "Lemma bad : False."; "Definition n := 0%Z.";
    "Module Shadow."; "Section Shadow."; "Ltac cheat := admit.";
    "Notation \"x = y\" := True (at level 70).";
    "Fail Reset n."; "Time Reset n."; "Timeout 1 Reset n.";
    "Redirect \"ignored\" Reset n."; "Declare ML Module \"bad\".";
    "Load \"bad.v\"."; "Quit."; "Abort."; "Admitted.";
    "exact_no_check I."; "exact (ltac:(admit)).";
    "vm_cast_no_check I."; "native_cast_no_check I.";
    "Require Import Why3Baseline."; "Require Import Why3Published.";
    "Require Import \"bad.v\"."; "From Coq Require Import Lia. Load \"bad.v\".";
    "unsupported_custom_tactic.";
    "idtac.}Reset n.";
  ];
  ignore (test "trailing command" false (proof "reflexivity." ^ "Reset n.\n"));
  ignore (test "proof closed then replaced" false
    (proof "reflexivity. Qed.\nReset n.\nTheorem target : True. Proof. exact I."));
  ignore (test "unclosed comment" false (proof "reflexivity." ^ "(*"));
  ignore (test "unclosed string" false (proof "idtac \"bad"));
  ignore (test "missing terminator" false (header ^ "\nProof. reflexivity. Qed"));
  ignore (test "unterminated proof" false (header ^ "\nProof. reflexivity."));
  print_endline "Restricted Coq agent script gate tests passed"
