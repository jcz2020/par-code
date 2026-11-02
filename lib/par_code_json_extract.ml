(* par_code_json_extract.ml — Lax JSON-object extraction shared by the judge
 * and the selector.
 *
 * Both agents are asked to reply with JSON only, but models wrap it in prose
 * or a fenced block anyway. Both consumers must agree on the same tolerance
 * rules, so the scanner lives here instead of being duplicated. *)

let extract_object (s : string) : string option =
  let len = String.length s in
  let start = ref (-1) in
  let depth = ref 0 in
  let found = ref None in
  let i = ref 0 in
  while !i < len && !found = None do
    (match s.[!i] with
     | '{' ->
       if !depth = 0 then start := !i;
       incr depth
     | '}' ->
       if !depth > 0 then decr depth;
       if !depth = 0 && !start >= 0 then
         found := Some (String.sub s !start (!i - !start + 1))
     | _ -> ());
    incr i
  done;
  !found
