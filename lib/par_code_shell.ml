(* par_code_shell — the `!command` passthrough.

   A line the user types as `!<command>` runs directly instead of going to the
   model. It is deliberately NOT a shell: there is no pipeline, globbing, or
   substitution, so what runs is exactly the argv that was typed. Permission
   deny rules still apply, because they express the operator's wishes about the
   repository, not about the agent. *)

let is_space = function ' ' | '\t' -> true | _ -> false

(** Split a command line into argv with shell-like quoting but no expansion:
    single quotes are literal, a backslash escapes the next byte, and an
    unterminated quote yields the tokens collected so far. *)
let split_argv (line : string) : string list =
  let n = String.length line in
  let tokens = ref [] in
  let buf = Buffer.create 16 in
  let in_token = ref false in
  let i = ref 0 in
  let flush () =
    if !in_token then begin
      tokens := Buffer.contents buf :: !tokens;
      Buffer.clear buf;
      in_token := false
    end
  in
  while !i < n do
    let c = line.[!i] in
    (match c with
     | c when is_space c ->
       flush ();
       incr i
     | '\'' ->
       in_token := true;
       incr i;
       while !i < n && line.[!i] <> '\'' do
         Buffer.add_char buf line.[!i];
         incr i
       done;
       if !i < n then incr i
     | '"' ->
       in_token := true;
       incr i;
       while !i < n && line.[!i] <> '"' do
         if line.[!i] = '\\' && !i + 1 < n then begin
           Buffer.add_char buf line.[!i + 1];
           i := !i + 2
         end else begin
           Buffer.add_char buf line.[!i];
           incr i
         end
       done;
       if !i < n then incr i
     | '\\' when !i + 1 < n ->
       in_token := true;
       Buffer.add_char buf line.[!i + 1];
       i := !i + 2
     | c ->
       in_token := true;
       Buffer.add_char buf c;
       incr i)
  done;
  flush ();
  List.rev !tokens

(** The deny rule that covers this command, if any. *)
let deny_reason (cmd : string) : string option =
  let ctx : Par.Hook.tool_call_context =
    { Par.Hook.tool_name = "bash";
      tool_call_id = "";
      input = `Assoc [ ("command", `String cmd) ];
      has_ui = true }
  in
  match Par_code_permissions.decide ~rules:(Par_code_permissions.load ()) ctx with
  | Some Par_code_permissions.Deny -> Some cmd
  | _ -> None

(** Run [argv] in [cwd] and capture its output. The command inherits the
    caller's stdin only if it asks for one; a passthrough command that needs a
    terminal is out of scope here. *)
let run ~(sw : Eio.Switch.t) ~(process_mgr : _ Eio.Process.mgr)
    ~(cwd : Eio.Fs.dir_ty Eio.Path.t) (argv : string list) :
    (int * string * string) option =
  match argv with
  | [] -> None
  | prog :: _ ->
    let out = Buffer.create 1024 in
    let err = Buffer.create 256 in
    let attempt () =
      let proc =
        Eio.Process.spawn ~sw process_mgr
          ~cwd
          ~stdin:(Eio.Flow.string_source "")
          ~stdout:(Eio.Flow.buffer_sink out)
          ~stderr:(Eio.Flow.buffer_sink err)
          argv
      in
      let status = Eio.Process.await proc in
      let code = match status with `Exited n -> n | `Signaled _ -> 128 in
      Some (code, Buffer.contents out, Buffer.contents err)
    in
    (try attempt ()
     with
     | Eio.Cancel.Cancelled _ as ex -> raise ex
     | ex ->
       let msg = Printexc.to_string ex in
       let contains hay needle =
         let nh = String.length hay and nn = String.length needle in
         let rec go i = i + nn <= nh && (String.sub hay i nn = needle || go (i + 1)) in
         nn > 0 && go 0
       in
       let msg =
         if contains msg "Executable_not_found" then
           Printf.sprintf "command not found: %s" prog
         else if msg = "" then Printf.sprintf "cannot run %s" prog
         else msg
       in
       Some (127, "", msg))
