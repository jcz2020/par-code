(* par_code_max_mode.ml — Best-of-N candidate fan-out.
 *
 * Each candidate runs Runtime.invoke on its own copy of the conversation with
 * ~update_current:false ~save:false, so the parent session is untouched until a
 * winner is adopted. Candidates are read-only by agent construction: the
 * max_candidate agent gets no write tools. *)

open Par

let candidate_agent_id = "max_candidate"

let candidate_system_prompt = {|
You are one of several independent candidates answering the same request.

You have read-only tools (read, grep, find, ls, memory queries, git inspection).
Use them to ground your answer in the actual code, then answer the request
completely and concretely. You cannot edit files or run commands — describe any
change precisely enough that another agent could apply it.

Never mention that you are a candidate; never compare yourself to others.
|}

let strategy_seeds = [
  "Angle: minimal change. Find the smallest correct change that satisfies the \
   request, and reuse the helpers that already exist instead of adding new \
   machinery.";
  "Angle: architecture. Read the surrounding design first, then propose the \
   approach that fits the existing structure, even if it touches more places.";
  "Angle: risk. Look for what could break - edge cases, error paths, tests that \
   would fail - and answer from that vantage point, naming the traps.";
]

let seed_for (index : int) : string =
  let n = List.length strategy_seeds in
  List.nth strategy_seeds (if n = 0 then 0 else index mod n)

let candidate_prompt ~(seed : string) ~(message : string) : string =
  Printf.sprintf
    "Your assigned angle for this answer:\n%s\n\n---\n\nUser request:\n%s" seed
    message

type candidate = {
  index : int;
  text : string;
  conversation : Types.conversation;
  usage : Types.usage_stats;
  events : Types.event list;
}

type outcome = {
  candidates : candidate list;
  failures : (int * string) list;
}

let empty_usage =
  { Types.prompt_tokens = 0
  ; completion_tokens = 0
  ; total_tokens = 0
  ; cached_tokens = 0
  ; cache_creation_input_tokens = 0
  ; cache_read_input_tokens = 0
  }

let add_usage (a : Types.usage_stats) (b : Types.usage_stats) : Types.usage_stats
    =
  { Types.prompt_tokens = a.Types.prompt_tokens + b.Types.prompt_tokens
  ; completion_tokens = a.Types.completion_tokens + b.Types.completion_tokens
  ; total_tokens = a.Types.total_tokens + b.Types.total_tokens
  ; cached_tokens = a.Types.cached_tokens + b.Types.cached_tokens
  ; cache_creation_input_tokens =
      a.Types.cache_creation_input_tokens + b.Types.cache_creation_input_tokens
  ; cache_read_input_tokens =
      a.Types.cache_read_input_tokens + b.Types.cache_read_input_tokens
  }

let merge_usage (usages : Types.usage_stats list) : Types.usage_stats =
  List.fold_left add_usage empty_usage usages

let candidate_usages (o : outcome) : Types.usage_stats list =
  List.map (fun c -> c.usage) o.candidates

let clamp_candidates (n : int) : int = if n < 2 then 2 else if n > 5 then 5 else n

let copy_conversation (c : Types.conversation) : Types.conversation =
  { c with Types.messages = c.Types.messages }

let error_to_string (e : Types.error_category) =
  match e with
  | Types.Timeout -> "Timeout"
  | Types.Invalid_input s -> Printf.sprintf "Invalid input: %s" s
  | Types.External_failure s -> Printf.sprintf "External failure: %s" s
  | Types.Rate_limited -> "Rate limited"
  | Types.Permission_denied s -> Printf.sprintf "Permission denied: %s" s
  | Types.Internal s -> Printf.sprintf "Internal error: %s" s
  | Types.Embedding_unsupported -> "Embedding unsupported"
  | Types.Cancelled Types.User_cancelled -> "Cancelled by user"
  | Types.Cancelled (Types.Guard_cancelled reason) ->
    Printf.sprintf "Cancelled by guard: %s" reason

let run_candidates ~(rt : Runtime.runtime) ~(agent_id : string)
    ~(message : string) ?(conversation : Types.conversation option)
    ?(system_prompt_appendix : string option) ~(n : int)
    ~(cancellation_token : Types.cancellation_token)
    ?(on_candidate_done : (int -> bool -> unit) option) () : outcome =
  let n = clamp_candidates n in
  let slots = Array.make n None in
  let failures = ref [] in
  let sem = Eio.Semaphore.make n in
  let report index ok =
    match on_candidate_done with Some f -> f index ok | None -> ()
  in
  let run_one i =
    Eio.Semaphore.acquire sem;
    Fun.protect
      ~finally:(fun () -> Eio.Semaphore.release sem)
      (fun () ->
         let prompt = candidate_prompt ~seed:(seed_for i) ~message in
         let conv_copy = Option.map copy_conversation conversation in
         let events = ref [] in
         match
           Runtime.invoke rt ~agent_id ~message:prompt ?conversation:conv_copy
             ?system_prompt_appendix ~update_current:false ~save:false
             ~on_tool_event:(fun e -> events := e :: !events)
             ~cancellation_token ()
         with
         | Ok r ->
           let text =
             match r.Types.response.Types.text with Some t -> t | None -> ""
           in
           slots.(i) <-
             Some
               { index = i
               ; text
               ; conversation = r.Types.conversation
               ; usage = r.Types.response.Types.usage
               ; events = List.rev !events
               };
           report i true
         | Error (e, _) ->
           failures := (i, error_to_string e) :: !failures;
           report i false)
  in
  Eio.Fiber.all (List.init n (fun i () -> run_one i));
  { candidates = List.filter_map (fun x -> x) (Array.to_list slots)
  ; failures = List.rev !failures
  }
