open Par

let approvals_path () =
  Filename.concat (Filename.concat (Sys.getcwd ()) ".par") "approvals.json"

let load () : string list =
  let path = approvals_path () in
  if not (Sys.file_exists path) then []
  else
    try
      let ic = open_in path in
      let n = in_channel_length ic in
      let s = Bytes.create n in
      really_input ic s 0 n;
      close_in ic;
      match Yojson.Safe.from_string (Bytes.to_string s) with
      | `List xs -> List.filter_map Yojson.Safe.Util.to_string_option xs
      | _ -> []
    with _ -> []

let add (pattern : string) : unit =
  let current = load () in
  let updated =
    if List.mem pattern current then current
    else current @ [pattern]
  in
  let path = approvals_path () in
  let par_dir = Filename.concat (Sys.getcwd ()) ".par" in
  if not (Sys.file_exists par_dir) then
    (try Unix.mkdir par_dir 0o755 with Unix.Unix_error _ -> ());
  let tmp = path ^ ".tmp" in
  let oc = open_out tmp in
  let json = `List (List.map (fun s -> `String s) updated) in
  output_string oc (Yojson.Safe.pretty_to_string ~std:true json);
  output_char oc '\n';
  close_out oc;
  Sys.rename tmp path

let matches (patterns : string list) (cmd : string) : bool =
  List.exists (fun pat ->
    if String.length pat > 0 && pat.[String.length pat - 1] = '*' then
      let prefix = String.sub pat 0 (String.length pat - 1) in
      String.length cmd >= String.length prefix &&
      String.sub cmd 0 (String.length prefix) = prefix
    else
      String.length cmd >= String.length pat &&
      String.sub cmd 0 (String.length pat) = pat
  ) patterns

type class_ =
  | In_project
  | External_path of string list
  | Sensitive of string list
  | Unknown

let delete_class_commands = ["rm"; "mv"; "dd"; "shred"; "truncate"]

let looks_like_path s =
  String.contains s '/' ||
  (String.length s > 0 && s.[0] = '.') ||
  (String.length s > 0 && s.[0] = '/')

let extract_redirect_targets s =
  let targets = ref [] in
  let len = String.length s in
  let i = ref 0 in
  while !i < len do
    if !i < len - 1 && s.[!i] = '>' then begin
      let j = ref (!i + 1) in
      if !j < len && s.[!j] = '>' then incr j;
      while !j < len && (s.[!j] = ' ' || s.[!j] = '\t') do incr j done;
      let start = !j in
      while !j < len && s.[!j] <> ' ' && s.[!j] <> ';' && s.[!j] <> '|' && s.[!j] <> '&' do incr j done;
      if !j > start then
        targets := String.sub s start (!j - start) :: !targets;
      i := !j
    end else
      incr i
  done;
  List.rev !targets

let extract_shell_string_args argv =
  let result = ref [] in
  let args = Array.of_list argv in
  for i = 0 to Array.length args - 1 do
    let a = args.(i) in
    if (a = "-c" || String.length a > 2 && String.sub a 0 2 = "-c") && i + 1 < Array.length args then begin
      let shell_str = args.(i + 1) in
      result := extract_redirect_targets shell_str @ !result;
      let tokens = String.split_on_char ' ' shell_str in
      List.iter (fun t ->
        if looks_like_path t then result := t :: !result
      ) tokens
    end
  done;
  !result

let classify (ws : Par.Workspace.workspace) ~(argv : string list) : class_ =
  let argv0 = match argv with x :: _ -> x | [] -> "" in
  let is_delete = List.exists (fun cmd -> argv0 = cmd) delete_class_commands in
  if is_delete then External_path [argv0]
  else
    let candidates = ref [] in
    List.iter (fun a ->
      if looks_like_path a then candidates := a :: !candidates
    ) argv;
    candidates := extract_shell_string_args argv @ !candidates;
    let candidates = List.rev !candidates in
    if candidates = [] then In_project
    else
      let external_paths = ref [] in
      let sensitive_paths = ref [] in
      let unknown = ref false in
      List.iter (fun c ->
        if not !unknown then
          match Workspace.admit ws c with
          | Ok _ -> ()
          | Error (Types.Invalid_input msg) when msg = "absolute path not under any workspace root" ->
            external_paths := c :: !external_paths
          | Error (Types.Permission_denied _) ->
            sensitive_paths := c :: !sensitive_paths
          | Error _ ->
            (* Error mapping table:
               - Invalid_input "path contains .." → Unknown (fail-closed)
               - Invalid_input "path contains :"  → Unknown (fail-closed)
               - any other error                  → Unknown (fail-closed)
               We treat all non-mapped errors as Unknown for safety. *)
            unknown := true
      ) candidates;
      if !unknown then Unknown
      else if !external_paths <> [] then External_path (List.rev !external_paths)
      else if !sensitive_paths <> [] then Sensitive (List.rev !sensitive_paths)
      else In_project
