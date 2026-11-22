(* par_code_edit_preview — the before picture for a file-changing tool call.

   The approval hook gets the tool name and its full input before the handler
   runs. This module turns that input into a title plus styled diff lines for
   the modal, and answers the policy question of whether to ask at all. *)

type body_line = string * Par_code_ui.style
type proposal = { title : string; body : body_line list }

let style = Par_code_ui.style

let starts_with s prefix =
  String.length s >= String.length prefix
  && String.sub s 0 (String.length prefix) = prefix

(** A diff line's colour: hunk headers cyan, additions green, removals red. *)
let diff_style (line : string) : Par_code_ui.style =
  if starts_with line "@@" then style ~fg:Par_code_ui.Cyan ~dim:true ()
  else if starts_with line "+++" || starts_with line "---" then
    style ~fg:Par_code_ui.Cyan ()
  else if starts_with line "+" then style ~fg:Par_code_ui.Green ()
  else if starts_with line "-" then style ~fg:Par_code_ui.Red ()
  else style ~dim:true ()

let max_read_bytes = 1_000_000

let read_file (path : string) : string option =
  try
    let ic = open_in_bin path in
    Fun.protect
      ~finally:(fun () -> close_in_noerr ic)
      (fun () ->
         let n = in_channel_length ic in
         if n > max_read_bytes then None else Some (really_input_string ic n))
  with _ -> None

(* The tool replaces the first occurrence of each "old" in order; mirror that
   here so the preview is what the handler will actually write. *)
let replace_first (old_ : string) (new_ : string) (s : string) : string option =
  if old_ = "" then None
  else begin
    let n = String.length s and m = String.length old_ in
    let rec find i =
      if i + m > n then None
      else if String.sub s i m = old_ then Some i
      else find (i + 1)
    in
    match find 0 with
    | None -> None
    | Some i ->
      Some (String.sub s 0 i ^ new_ ^ String.sub s (i + m) (n - i - m))
  end

let first_line s =
  match String.index_opt s '\n' with Some i -> String.sub s 0 i | None -> s

let apply_edits (content : string) (edits : (string * string) list) :
    (string, string) result =
  let rec go acc = function
    | [] -> Ok acc
    | (old_, new_) :: tl ->
      (match replace_first old_ new_ acc with
       | Some next -> go next tl
       | None -> Error (first_line old_))
  in
  go content edits

let resolve (cwd : string) (path : string) =
  if Filename.is_relative path then Filename.concat cwd path else path

let unified_body ~(old_text : string) ~(new_text : string) : body_line list =
  Par_code_diff.unified ~context:3 ~old_text ~new_text
  |> List.map (fun line -> (line, diff_style line))

let string_field (json : Yojson.Safe.t) key =
  match Yojson.Safe.Util.member key json with
  | `String s -> Some s
  | _ -> None

let edits_of (json : Yojson.Safe.t) : (string * string) list =
  match Yojson.Safe.Util.member "edits" json with
  | `List items ->
    List.filter_map
      (fun e ->
         match string_field e "old", string_field e "new" with
         | Some o, Some n -> Some (o, n)
         | _ -> None)
      items
  | _ -> []

(** The dialog content for a tool call, or [None] when the tool does not touch
    files (the caller then allows it without a dialog). *)
let for_tool ~(cwd : string) ~(tool : string) ~(input : Yojson.Safe.t) :
    proposal option =
  match String.lowercase_ascii tool with
  | "write" | "write_file" ->
    (match string_field input "path" with
     | None -> None
     | Some path ->
       let content = Option.value (string_field input "content") ~default:"" in
       let full = resolve cwd path in
       let old = Option.value (read_file full) ~default:"" in
       let title =
         if old = "" then Printf.sprintf "Create %s" path
         else Printf.sprintf "Overwrite %s" path
       in
       Some { title; body = unified_body ~old_text:old ~new_text:content })
  | "edit" | "str_replace" ->
    (match string_field input "path" with
     | None -> None
     | Some path ->
       let full = resolve cwd path in
       let old = Option.value (read_file full) ~default:"" in
       let edits = edits_of input in
       let title = Printf.sprintf "Edit %s" path in
       (match apply_edits old edits with
        | Error missing ->
          Some
            { title;
              body =
                [ (Printf.sprintf "⚠ this edit does not match the current file", style ~fg:Par_code_ui.Yellow ());
                  (Printf.sprintf "  first missing text: %s" missing, style ~dim:true ()) ] }
        | Ok next -> Some { title; body = unified_body ~old_text:old ~new_text:next }))
  | "apply_patch" ->
    (match string_field input "patch" with
     | None -> None
     | Some patch ->
       let lines = String.split_on_char '\n' patch in
       Some
         { title = "Apply patch";
           body = List.map (fun line -> (line, diff_style line)) lines })
  | _ -> None

(* "a" in the dialog allows further edits for the rest of this process. *)
let allow_session = ref false

let has_git_root (start : string) : bool =
  let rec go dir =
    if Sys.file_exists (Filename.concat dir ".git") then true
    else
      let parent = Filename.dirname dir in
      if parent = dir then false else go parent
  in
  try go start with _ -> false

(** [policy] is the config value: ask / auto_project / always. *)
let should_ask ~(policy : string) : bool =
  if !allow_session then false
  else
    match policy with
    | "always" -> false
    | "auto_project" -> not (has_git_root (Sys.getcwd ()))
    | _ -> true
