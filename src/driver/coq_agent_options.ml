(********************************************************************)
(* The Why3 Verification Platform / The Why3 Development Team         *)
(* Copyright 2010-2026 -- Inria - CNRS - Paris-Saclay University        *)
(* Distributed under the GNU LGPL version 2.1, with the exception      *)
(* described in the file LICENSE.                                    *)
(********************************************************************)

let profile_override = ref None

let profile_option =
  Getopt.(KLong "coq-agent-profile", Hnd1 (AString, fun name -> profile_override := Some name),
    "<name> select the Coq agent model profile")
