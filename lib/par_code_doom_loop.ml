type action =
  | Continue
  | Nudge of string
  | Force_judge of string
  | Abort of string

type t = {
  threshold : int;
  mutable last_hash : int;
  mutable streak : int;
  mutable nudge_sent : bool;
  mutable judge_forced : bool;
}

let create ?(threshold = 3) () = {
  threshold;
  last_hash = 0;
  streak = 0;
  nudge_sent = false;
  judge_forced = false;
}

let streak_count t = t.streak

let hash_call ~tool_name ~args =
  Hashtbl.hash (tool_name, Yojson.Safe.to_string args)

let record_call t ~tool_name ~args =
  let h = hash_call ~tool_name ~args in
  if h = t.last_hash && t.streak > 0 then
    t.streak <- t.streak + 1
  else begin
    t.streak <- 1;
    t.last_hash <- h;
    t.nudge_sent <- false;
    t.judge_forced <- false
  end;
  let n = t.streak in
  let thr = t.threshold in
  if n >= thr * 3 then
    Abort (Printf.sprintf "Tool '%s' called %d times consecutively — aborting goal" tool_name n)
  else if n >= thr * 2 && not t.judge_forced then begin
    t.judge_forced <- true;
    Force_judge (Printf.sprintf "Tool '%s' called %d times — forcing judge evaluation" tool_name n)
  end
  else if n >= thr && not t.nudge_sent then begin
    t.nudge_sent <- true;
    Nudge (Printf.sprintf "Tool '%s' called %d times identically — reassess your approach" tool_name n)
  end
  else
    Continue

let record_tool_call t tool_name =
  record_call t ~tool_name ~args:`Null
