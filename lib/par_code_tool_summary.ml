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

(** What came back, from the result preview. *)
let of_result ~(name : string) (preview : string option) : string =
  match preview with
  | None -> ""
  | Some p when String.trim p = "" -> ""
  | Some p ->
    let n = count_lines p in
    (match String.lowercase_ascii name with
     | "read" | "read_file" -> Printf.sprintf "%d lines" n
     | "grep" -> Printf.sprintf "%d matches" n
     | "find" | "glob" -> Printf.sprintf "%d results" n
     | "ls" | "list" -> Printf.sprintf "%d entries" n
     | "bash" -> clip p
     | "write" | "write_file" | "edit" | "str_replace" | "apply_patch" -> clip p
     | _ -> if n > 1 then Printf.sprintf "%d lines" n else "")

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
