(* par_code_payload.ml — conversation payload hygiene.

 * Two history shapes are rejected by strict providers but can be produced
   locally before a request is sent:
   - a Tool result whose announcing Assistant tool_call has been cut away by
     context truncation ("tool result's tool id ... not found", HTTP 400 2013);
   - a tool_call whose arguments are not a JSON object, typically `null`
     ("invalid params", HTTP 400 2013).

   Both were observed against a live provider on v0.8.0. Sanitizing on the way
   into an invoke (and on the way out of an error or a resumed session) keeps a
   single malformed message from poisoning every later turn. *)

open Par

let normalize_arguments (args : Yojson.Safe.t) : Yojson.Safe.t =
  match args with `Assoc _ -> args | _ -> `Assoc []

let normalize_tool_call (tc : Types.tool_call) : Types.tool_call =
  { tc with Types.arguments = normalize_arguments tc.Types.arguments }

let normalize_message (m : Types.message) : Types.message =
  match m.Types.tool_calls with
  | None -> m
  | Some calls ->
    { m with Types.tool_calls = Some (List.map normalize_tool_call calls) }

let sanitize (conv : Types.conversation) : Types.conversation =
  let announced = Hashtbl.create 16 in
  let keep =
    List.filter_map
      (fun (m : Types.message) ->
        match m.Types.role with
        | Types.Assistant ->
          (match m.Types.tool_calls with
           | Some calls ->
             List.iter
               (fun (tc : Types.tool_call) ->
                 if tc.Types.id <> "" then Hashtbl.replace announced tc.Types.id ())
               calls
           | None -> ());
          Some (normalize_message m)
        | Types.Tool ->
          (match m.Types.tool_call_id with
           | Some id when id <> "" && Hashtbl.mem announced id -> Some m
           | _ -> None)
        | Types.System | Types.User -> Some m)
      conv.Types.messages
  in
  { conv with Types.messages = keep }
