(********************************************************************)
(*                                                                  *)
(*  The Why3 Verification Platform   /   The Why3 Development Team  *)
(*  Copyright 2010-2025 --  Inria - CNRS - Paris-Saclay University  *)
(*                                                                  *)
(*  This software is distributed under the terms of the GNU Lesser  *)
(*  General Public License version 2.1, with the special exception  *)
(*  on linking described in file LICENSE.                           *)
(********************************************************************)



(*

This is extracted/adapted from the code found in the book Real World
Ocaml by Yaron Minsky, Anil Madhavapeddy, and Jason Hickey. Their
'unlicence' allows it.

*)

(* A JSON text can actually be any JSON value *)

%start <Json_base.json> value
%start <Json_base.json> document
%token <int> INT
%token <float> FLOAT
%token <string> STRING
%token TRUE
%token FALSE
%token NULL
%token LEFTBRC RIGHTBRC
%token LEFTSQ
%token RIGHTSQ
%token COLON
%token COMMA
%token EOF
%%

/* Complete documents distinguish empty objects from null and require EOF.
   Keep the legacy value entry point unchanged for existing protocol users. */
document:
| document_value EOF { $1 }

document_value:
| STRING { Json_base.String $1 }
| INT { Json_base.Int $1 }
| FLOAT { Json_base.Float $1 }
| TRUE { Json_base.Bool true }
| FALSE { Json_base.Bool false }
| NULL { Json_base.Null }
| LEFTBRC RIGHTBRC { Json_base.Record [] }
| LEFTBRC document_members RIGHTBRC { Json_base.Record (List.rev $2) }
| LEFTSQ RIGHTSQ { Json_base.List [] }
| LEFTSQ document_elements RIGHTSQ { Json_base.List (List.rev $2) }

document_members:
| STRING COLON document_value { [($1, $3)] }
| document_members COMMA STRING COLON document_value { ($3, $5) :: $1 }

document_elements:
| document_value { [$1] }
| document_elements COMMA document_value { $3 :: $1 }

json_object:
| EOF { Json_base.Null }
| LEFTBRC RIGHTBRC { Json_base.Null }
(* Left recursive rule are more efficient *)
| LEFTBRC members RIGHTBRC {
  Json_base.Record (List.rev $2) }

members:
| json_pair { [ $1 ] }
| members COMMA json_pair { $3 :: $1 }

array:
| LEFTSQ RIGHTSQ { Json_base.List [] }
| LEFTSQ elements RIGHTSQ { Json_base.List (List.rev $2) }

elements:
| value { [$1] }
| elements COMMA value { $3 :: $1 }

json_pair:
| STRING COLON value { ($1, $3) }

value:
| STRING { Json_base.String $1 }
| INT { Json_base.Int $1 }
| FLOAT { Json_base.Float $1 }
| json_object { $1 }
| array { $1 }
| TRUE { Json_base.Bool true}
| FALSE { Json_base.Bool false }
| NULL { Json_base.Null }
