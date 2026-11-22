(* par_code_tool_summary — the one-line description of a tool call.

   A transcript that says only "✓ read (1.2ms)" tells you nothing about what was
   read. Each call is summarised from its arguments (what was asked) and, when
   it finishes, from its result preview (what came back), in the compact style
   used by other terminal agents: `✓ read lib/par_code_screen.ml · 812 lines`.*)

let limit = 64

let clip (s : string) : string =
  let s = String.trim s in
  let s =
    (* One line only: a summary never wraps. *)
    match String.index_opt s '\n' with
    | Some i -> String.sub s 0 i
    | None -> s
  in
  if String.length s > limit then String.sub s 0 (limit - 1) ^ "…" else s

let get_string (json : Yojson.Safe.t) (keys : string list) : string option =
  let rec go = function
    | [] -> None
    | k :: rest ->
      (match Yojson.Safe.Util.member k json with
       | `String s when String.trim s <> "" -> Some s
       | `List (x :: _) -> (match x with `String s -> Some s | _ -> None)
       | _ -> go rest)
  in
  go keys

(** What the call asked for, from its arguments. *)
let of_arguments ~(name : string) (args : Yojson.Safe.t) : string =
  let s keys = get_string args keys in
  match String.lowercase_ascii name with
  | "read" | "read_file" -> Option.value (s [ "path"; "file"; "file_path" ]) ~default:""
  | "write" | "write_file" -> Option.value (s [ "path"; "file"; "file_path" ]) ~default:""
  | "edit" | "str_replace" -> Option.value (s [ "path"; "file"; "file_path" ]) ~default:""
  | "apply_patch" -> Option.value (s [ "path"; "file" ]) ~default:""
  | "ls" | "list" -> Option.value (s [ "path"; "dir" ]) ~default:"."
  | "grep" ->
    (match s [ "pattern"; "query" ] with
     | Some p -> (match s [ "path" ] with Some d -> Printf.sprintf "%s in %s" p d | None -> p)
     | None -> "")
  | "find" | "glob" -> Option.value (s [ "pattern"; "glob" ]) ~default:""
  | "bash" ->
    (match s [ "command"; "cmd" ] with
     | Some c -> c
     | None ->
       (match Yojson.Safe.Util.member "argv" args with
        | `List l ->
          String.concat " "
            (List.filter_map (function `String x -> Some x | _ -> None) l)
        | _ -> ""))
  | "recall_memory" | "remember_memory" ->
    Option.value (s [ "query"; "summary"; "content" ]) ~default:""
  | "delegate" | "delegate_batch" ->
    (match s [ "agent"; "input"; "task" ] with Some v -> v | None -> "")
  | _ ->
    (* Unknown tool: show the first string in the object, if any. *)
    (match args with
     | `Assoc fields ->
       (match List.find_map (function _, `String v -> Some v | _ -> None) fields with
        | Some v -> v
        | None -> "")
     | _ -> "")

let count_lines (s : string) : int =
  if s = "" then 0
  else
    let n = ref 1 in
    String.iter (fun c -> if c = '\n' then incr n) s;
    if s.[String.length s - 1] = '\n' then !n - 1 else !n

(* The SDK hands the preview over as [Yojson.Safe.to_string output], not as the
   text the tool returned. Newlines arrive as the two characters \\n, so the
   old line count said "1 lines" for every read, and bash showed the raw
   {"stdout":…} blob. Decode the payload before summarising it. *)
let preview_json (p : string) : Yojson.Safe.t option =
  match Yojson.Safe.from_string p with
  | json -> Some json
  | exception _ -> None

let string_field (fields : (string * Yojson.Safe.t) list) (keys : string list) :
    string option =
  List.find_map
    (fun k ->
       match List.assoc_opt k fields with
       | Some (`String s) when String.trim s <> "" -> Some s
       | _ -> None)
    keys

(** The text a structured result carries, whichever field holds it. *)
let text_of_json (json : Yojson.Safe.t) : string =
  match json with
  | `String s -> s
  | `List l ->
    String.concat "\n"
      (List.filter_map (function `String s -> Some s | _ -> None) l)
  | `Assoc fields ->
    (match
       string_field fields
         [ "content"; "stdout"; "stderr"; "text"; "output"; "message";
           "result" ]
     with
     | Some s -> s
     | None ->
       String.concat "\n"
         (List.filter_map (function _, `String s -> Some s | _ -> None) fields))
  | _ -> ""

(* A preview longer than 500 bytes is cut mid-string by the engine and gets
   "... (N bytes total)" appended, so it no longer parses. Pull the first
   string field out by hand in that case; escapes are still recoverable. *)
let json_unescape (s : string) : string =
  let b = Buffer.create (String.length s) in
  let i = ref 0 in
  let n = String.length s in
  while !i < n do
    (match s.[!i] with
     | '\\' when !i + 1 < n ->
       incr i;
       (match s.[!i] with
        | 'n' -> Buffer.add_char b '\n'
        | 't' -> Buffer.add_char b '\t'
        | 'r' -> Buffer.add_char b '\r'
        | c -> Buffer.add_char b c)
     | c -> Buffer.add_char b c);
    incr i
  done;
  Buffer.contents b

let find_sub (needle : string) (hay : string) : int option =
  let nl = String.length needle and hl = String.length hay in
  if nl = 0 then Some 0
  else begin
    let rec go i =
      if i + nl > hl then None
      else if String.sub hay i nl = needle then Some i
      else go (i + 1)
    in
    go 0
  end

let lenient_text (p : string) : string option =
  let keys = [ "content"; "stdout"; "stderr"; "text"; "output"; "message"; "result" ] in
  let find key =
    let pat = "\"" ^ key ^ "\":\"" in
    match find_sub pat p with
    | None -> None
    | Some i ->
      let start = i + String.length pat in
      (* read to the next unescaped quote *)
      let j = ref start in
      let n = String.length p in
      while
        !j < n
        && not (p.[!j] = '"' && (!j = start || p.[!j - 1] <> '\\'))
      do
        incr j
      done;
      if !j > start then Some (String.sub p start (!j - start)) else None
  in
  List.find_map find keys |> Option.map json_unescape

let escaped_newline_count (s : string) : int =
  let n = String.length s in
  let count = ref 0 in
  let i = ref 0 in
  while !i < n - 1 do
    if s.[!i] = '\\' && s.[!i + 1] = 'n' then begin
      incr count;
      i := !i + 2
    end else incr i
  done;
  !count

(** What came back, from the result preview. *)
let of_result ~(name : string) (preview : string option) : string =
  match preview with
  | None -> ""
  | Some p when String.trim p = "" -> ""
  | Some p ->
    let lower = String.lowercase_ascii name in
    let json = preview_json p in
    let decoded =
      match json with
      | Some j ->
        let t = text_of_json j in
        if t = "" then None else Some t
      | None -> lenient_text p
    in
    let n =
      match decoded with
      | Some t -> count_lines t
      | None -> max (count_lines p) (escaped_newline_count p + 1)
    in
    let text = match decoded with Some t -> t | None -> p in
    (* The engine cuts a preview at 500 bytes and appends "... (N bytes total)".
       The count then describes only what fits, so say so instead of reporting a
       file's full line count as if it were measured. *)
    let cut = find_sub " bytes total)" p <> None in
    let plural k one many =
      if cut then Printf.sprintf "%d+ %s" k many
      else Printf.sprintf "%d %s" k (if k = 1 then one else many)
    in
    if lower = "bash" then begin
      let head s =
        let s = String.trim s in
        match String.index_opt s '\n' with
        | Some i -> clip (String.sub s 0 i)
        | None -> clip s
      in
      match json with
      | Some (`Assoc fields) ->
        let str k =
          match List.assoc_opt k fields with Some (`String s) -> s | _ -> ""
        in
        let code =
          match List.assoc_opt "exit_code" fields with
          | Some (`Int i) -> Some i
          | _ -> None
        in
        let out = str "stdout" and err = str "stderr" in
        let body =
          if String.trim out <> "" then head out
          else if String.trim err <> "" then head err
          else ""
        in
        let status =
          match code with
          | Some 0 | None -> ""
          | Some c -> Printf.sprintf "exit %d" c
        in
        String.concat " · " (List.filter (fun s -> s <> "") [ status; body ])
      | _ -> head text
    end
    else
      match lower with
      | "read" | "read_file" -> plural n "line" "lines"
      | "grep" -> plural n "match" "matches"
      | "find" | "glob" -> plural n "result" "results"
      | "ls" | "list" ->
        (match json with
         | Some (`Assoc fields) ->
           (match List.assoc_opt "entries" fields with
            | Some (`List l) -> plural (List.length l) "entry" "entries"
            | _ -> plural n "entry" "entries")
         | Some (`List l) -> plural (List.length l) "entry" "entries"
         | _ -> plural n "entry" "entries")
      | "apply_patch" ->
        (match json with
         | Some (`Assoc fields) ->
           let i k =
             match List.assoc_opt k fields with Some (`Int v) -> v | _ -> 0
           in
           let files = i "files_changed" in
           let ins = i "insertions" and del = i "deletions" in
           if files = 0 && ins = 0 && del = 0 then ""
           else
             Printf.sprintf "%d %s · +%d/-%d" files
               (if files = 1 then "file" else "files")
               ins del
         | _ -> "")
      | "write" | "write_file" | "edit" | "str_replace" -> clip text
      | _ -> if n > 1 then plural n "line" "lines" else ""

(** The whole line: name, what it touched, result size, duration. *)
let line ~(name : string) ~(args : Yojson.Safe.t option) ~(preview : string option)
    ~(duration_ms : float option) ~(failed : bool) : string =
  let asked =
    match args with None -> "" | Some a -> clip (of_arguments ~name a)
  in
  let got = if failed then "" else of_result ~name preview in
  let parts =
    List.filter (fun s -> String.trim s <> "")
      [ name; asked; got ]
  in
  let tail =
    match duration_ms with
    | None -> ""
    | Some d when d >= 1000.0 -> Printf.sprintf "%.1fs" (d /. 1000.0)
    | Some d -> Printf.sprintf "%.1fms" d
  in
  String.concat " · " (parts @ if tail = "" then [] else [ tail ])
