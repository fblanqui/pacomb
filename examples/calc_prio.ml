open Pacomb
open Grammar
open Pos

(*  This  example  (read  calc.ml  first)  illustrates  another  way  to  handle
   priorities with parametric grammars. *)

(* The three levels of priorities *)
type p = Atom | Prod | Sum
let%parser rec
              (* This includes each priority level in the next one *)
     expr p = Atom < Prod < Sum
            (* all other rule are selected by their priority level *)
            ; (p=Atom) (x::FLOAT)                        => x
            ; (p=Atom) '(' (e::expr Sum) ')'             => e
            ; (p=Prod) (x::expr Prod) '*' (y::expr Atom) => x*.y
            ; (p=Prod) (x::expr Prod) '/' (y::expr Atom) => x/.y
            ; (p=Sum ) (x::expr Sum ) '+' (y::expr Prod) => x+.y
            ; (p=Sum ) (x::expr Sum ) '-' (y::expr Prod) => x-.y

let blank = Lex.blank_charset (Charset.singleton ' ')

let _ =
  try
    while true do
      let f () =
        Printf.printf "=> %!";
        let line = input_line stdin in
        let n = parse_string (expr Sum) blank line in
        Printf.printf "%f\n%!" n
      in handle_exception ~error:(fun _ -> ()) f ()
    done
  with
    End_of_file -> ()