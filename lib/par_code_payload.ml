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
  (* v0.15.3: providers require a tool result to sit immediately after the
     assistant message that announced its call. After an aborted turn the
     conversation can hold a result whose call was pruned or reordered, and the
     whole request is then rejected ("Tool result call_... has no matching
     call"). Pass 1 keeps only adjacent, single-use results; pass 2 drops calls
     that lost their result, so both directions stay consistent. *)
  let pending = ref [] in
  let kept =
    List.filter_map
      (fun (m : Types.message) ->
        match m.Types.role with
        | Types.Assistant ->
          pending :=
            (match m.Types.tool_calls with
             | Some calls ->
               List.filter_map
                 (fun (tc : Types.tool_call) ->
                   if tc.Types.id = "" then None else Some tc.Types.id)
                 calls
             | None -> []);
          Some (normalize_message m)
        | Types.Tool ->
          (match m.Types.tool_call_id with
           | Some id when List.mem id !pending ->
             pending := List.filter (fun x -> x <> id) !pending;
             Some m
           | _ -> None)
        | Types.System | Types.User ->
          pending := [];
          Some m)
      conv.Types.messages
  in
  let has_result id rest =
    List.exists
      (fun (n : Types.message) ->
        n.Types.role = Types.Tool && n.Types.tool_call_id = Some id)
      rest
  in
  let rec fix = function
    | [] -> []
    | (m : Types.message) :: rest ->
      (match m.Types.role, m.Types.tool_calls with
       | Types.Assistant, Some calls ->
         let live =
           List.filter (fun (tc : Types.tool_call) -> has_result tc.Types.id rest)
             calls
         in
         let m =
           { m with Types.tool_calls = (if live = [] then None else Some live) }
         in
         m :: fix rest
       | _ -> m :: fix rest)
  in
  { conv with Types.messages = fix kept }
