(* par_code_diff — a small line diff for the edit approval dialog.

   The dialog only needs to answer "what will this call change", so this is a
   plain LCS over lines with a hunk layout familiar from git. It is bounded:
   two huge inputs degrade to "all removed, all added" instead of allocating a
   quadratic table on a phone. *)

type op = Keep of string | Del of string | Add of string

let split_lines (s : string) : string list =
  if s = "" then []
  else
    let lines = String.split_on_char '\n' s in
    (* A trailing newline produces one empty element that is not a line. *)
    match List.rev lines with
    | "" :: rest -> List.rev rest
    | _ -> lines

(* Above this many cells the table would cost more memory than the preview is
   worth; the fallback still shows every old and new line, just not paired. *)
let max_cells = 4_000_000

let ops (old_text : string) (new_text : string) : op list =
  let a = Array.of_list (split_lines old_text) in
  let b = Array.of_list (split_lines new_text) in
  let n = Array.length a and m = Array.length b in
  if n * m > max_cells then
    List.map (fun l -> Del l) (Array.to_list a)
    @ List.map (fun l -> Add l) (Array.to_list b)
  else begin
    let dp = Array.make_matrix (n + 1) (m + 1) 0 in
    for i = n - 1 downto 0 do
      for j = m - 1 downto 0 do
        dp.(i).(j) <-
          (if a.(i) = b.(j) then dp.(i + 1).(j + 1) + 1
           else max dp.(i + 1).(j) dp.(i).(j + 1))
      done
    done;
    let out = ref [] in
    let i = ref 0 and j = ref 0 in
    while !i < n || !j < m do
      if !i < n && !j < m && a.(!i) = b.(!j) then begin
        out := Keep a.(!i) :: !out;
        incr i;
        incr j
      end else if
        !j < m && (!i >= n || dp.(!i).(!j + 1) > dp.(!i + 1).(!j))
      then begin
        out := Add b.(!j) :: !out;
        incr j
      end else begin
        out := Del a.(!i) :: !out;
        incr i
      end
    done;
    List.rev !out
  end

(* How many lines a preview may occupy before it is cut. *)
let max_preview_lines = 60

(** Render [ops] in unified-diff format with [context] unchanged lines around
    each run of changes. Returns [] when nothing changed. *)
let unified_ops ~(context : int) (ops : op list) : string list =
  let arr = Array.of_list ops in
  let n = Array.length arr in
  let old_at = Array.make (n + 1) 0 and new_at = Array.make (n + 1) 0 in
  Array.iteri
    (fun i op ->
       old_at.(i + 1) <- old_at.(i) + (match op with Keep _ | Del _ -> 1 | Add _ -> 0);
       new_at.(i + 1) <- new_at.(i) + (match op with Keep _ | Add _ -> 1 | Del _ -> 0))
    arr;
  let changes = ref [] in
  Array.iteri (fun i op -> match op with Keep _ -> () | _ -> changes := i :: !changes) arr;
  let changes = List.rev !changes in
  if changes = [] then []
  else begin
    (* Group changes whose context windows touch. *)
    let groups = ref [] in
    List.iter
      (fun idx ->
         match !groups with
         | (s, e) :: rest when idx - e <= 2 * context -> groups := (s, idx) :: rest
         | _ -> groups := (idx, idx) :: !groups)
      changes;
    let groups = List.rev !groups in
    let out = ref [] in
    let truncated = ref false in
    List.iter
      (fun (s, e) ->
         if not !truncated then begin
           let start = max 0 (s - context) in
           let stop = min (n - 1) (e + context) in
           let old_count = ref 0 and new_count = ref 0 in
           for k = start to stop do
             (match arr.(k) with
              | Keep _ -> incr old_count; incr new_count
              | Del _ -> incr old_count
              | Add _ -> incr new_count)
           done;
           out :=
             Printf.sprintf "@@ -%d,%d +%d,%d @@"
               (old_at.(start) + 1) !old_count (new_at.(start) + 1) !new_count
             :: !out;
           for k = start to stop do
             if not !truncated then begin
               let line =
                 match arr.(k) with
                 | Keep l -> " " ^ l
                 | Del l -> "-" ^ l
                 | Add l -> "+" ^ l
               in
               out := line :: !out;
               if List.length !out >= max_preview_lines then begin
                 truncated := true;
                 out := "  … (diff truncated)" :: !out
               end
             end
           done
         end)
      groups;
    List.rev !out
  end

let unified ~(context : int) ~(old_text : string) ~(new_text : string) :
    string list =
  unified_ops ~context (ops old_text new_text)
