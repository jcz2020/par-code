(* par_code_ui_markdown.ml — Streaming markdown to ANSI renderer.
 *
 * Consumes incremental text chunks (e.g., from an LLM token stream) and
 * produces ANSI-styled strings. Line-based: incomplete markdown constructs
 * are buffered, and only complete lines are emitted per [push].
 *
 * Round-trip property: chunked input produces identical output to whole
 * input. This holds because state carries only [ctx] (code-block flag)
 * and the partial current line; each complete line is rendered
 * independently given [ctx]; [flush] renders the trailing partial
 * identically to a final line emitted by [push].
 *
 * No external dependencies (stdlib only). No regex lib. *)

(* -------------------------------------------------------------------------- *)
(* ANSI escape sequences                                                      *)
(* -------------------------------------------------------------------------- *)

let esc = "\027"

let reset = esc ^ "[0m"
let ansi_bold = esc ^ "[1m"
let ansi_dim = esc ^ "[2m"
let ansi_italic = esc ^ "[3m"
let ansi_underline = esc ^ "[4m"
let ansi_reverse = esc ^ "[7m"
let ansi_cyan = esc ^ "[36m"

let wrap_bold s = ansi_bold ^ s ^ reset
let wrap_italic s = ansi_italic ^ s ^ reset
let wrap_inline_code s = ansi_dim ^ ansi_reverse ^ s ^ reset
let wrap_code_line s = ansi_dim ^ s ^ reset
let wrap_heading s = ansi_bold ^ ansi_cyan ^ s ^ reset
let wrap_link_text s = ansi_underline ^ s ^ reset
let wrap_link_url s = ansi_dim ^ s ^ reset

(* -------------------------------------------------------------------------- *)
(* String helpers (no regex lib)                                              *)
(* -------------------------------------------------------------------------- *)

let starts_with s prefix =
  let plen = String.length prefix in
  String.length s >= plen && String.sub s 0 plen = prefix

(* Find next occurrence of [sub] in [s] starting at [from]. O(n*m) but fine
   for typical LLM line lengths (hundreds of chars). *)
let index_of_substring ~from s sub =
  let slen = String.length s in
  let sublen = String.length sub in
  if sublen = 0 then Some from
  else if from + sublen > slen then None
  else begin
    let rec loop i =
      if i + sublen > slen then None
      else if String.sub s i sublen = sub then Some i
      else loop (i + 1)
    in
    loop from
  end

let is_space c = c = ' ' || c = '\t' || c = '\n' || c = '\r'

let is_alnum c =
  (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')

(* -------------------------------------------------------------------------- *)
(* State                                                                      *)
(* -------------------------------------------------------------------------- *)

type ctx =
  | Normal
  | InCodeBlock of { lang : string }

type state = {
  ctx : ctx;
  line_buf : string;
}

let initial : state = { ctx = Normal; line_buf = "" }

let reset () = ()

(* -------------------------------------------------------------------------- *)
(* Inline parser                                                              *)
(*                                                                            *)
(* Single-pass scanner over a complete line. Recognizes (no nesting):        *)
(*   - `code`                                                                 *)
(*   - **bold** / __bold__                                                    *)
(*   - *italic* / _italic_  (skips mid-word markers to avoid false positives) *)
(*   - [text](url)                                                            *)
(* Unmatched markers emit literally.                                         *)
(* -------------------------------------------------------------------------- *)

(* Try to parse [text](url) starting at position [i] (which is '[').
   Returns Some (text, url, next_pos) if matched. *)
let try_parse_link line i =
  let len = String.length line in
  if i >= len || line.[i] <> '[' then None
  else
    match String.index_from_opt line (i + 1) ']' with
    | None -> None
    | Some close_bracket ->
      let text = String.sub line (i + 1) (close_bracket - i - 1) in
      let after_bracket = close_bracket + 1 in
      if after_bracket >= len || line.[after_bracket] <> '(' then None
      else
        match String.index_from_opt line (after_bracket + 1) ')' with
        | None -> None
        | Some close_paren ->
          let url = String.sub line (after_bracket + 1)
                      (close_paren - after_bracket - 1) in
          Some (text, url, close_paren + 1)

let parse_inline line =
  let len = String.length line in
  let out = Buffer.create (len * 2 + 16) in
  let pos = ref 0 in
  while !pos < len do
    let i = !pos in
    let c = line.[i] in
    if c = '`' then begin
      match String.index_from_opt line (i + 1) '`' with
      | Some close_pos ->
        let code = String.sub line (i + 1) (close_pos - i - 1) in
        Buffer.add_string out (wrap_inline_code code);
        pos := close_pos + 1
      | None ->
        Buffer.add_char out c;
        pos := i + 1
    end
    else if c = '*' && i + 1 < len && line.[i + 1] = '*' then begin
      match index_of_substring ~from:(i + 2) line "**" with
      | Some close_pos ->
        let inner = String.sub line (i + 2) (close_pos - i - 2) in
        Buffer.add_string out (wrap_bold inner);
        pos := close_pos + 2
      | None ->
        Buffer.add_string out "**";
        pos := i + 2
    end
    else if c = '_' && i + 1 < len && line.[i + 1] = '_' then begin
      match index_of_substring ~from:(i + 2) line "__" with
      | Some close_pos ->
        let inner = String.sub line (i + 2) (close_pos - i - 2) in
        Buffer.add_string out (wrap_bold inner);
        pos := close_pos + 2
      | None ->
        Buffer.add_string out "__";
        pos := i + 2
    end
    else if (c = '*' || c = '_')
            && i + 1 < len
            && not (is_space line.[i + 1])
            && (c = '*' || i = 0 || not (is_alnum line.[i - 1])) then begin
      (* Italic single marker. Asymmetric rule: '_' requires preceding
         char to be non-alphanumeric (otherwise snake_case_var matches);
         '*' only requires non-whitespace after. *)
      match String.index_from_opt line (i + 1) c with
      | Some close_pos ->
        let inner = String.sub line (i + 1) (close_pos - i - 1) in
        if String.length inner > 0 && not (is_space inner.[0]) then begin
          Buffer.add_string out (wrap_italic inner);
          pos := close_pos + 1
        end else begin
          Buffer.add_char out c;
          pos := i + 1
        end
      | None ->
        Buffer.add_char out c;
        pos := i + 1
    end
    else if c = '[' then begin
      match try_parse_link line i with
      | Some (text, url, next) ->
        Buffer.add_string out (wrap_link_text text);
        Buffer.add_string out " (";
        Buffer.add_string out (wrap_link_url url);
        Buffer.add_char out ')';
        pos := next
      | None ->
        Buffer.add_char out '[';
        pos := i + 1
    end
    else begin
      Buffer.add_char out c;
      pos := i + 1
    end
  done;
  Buffer.contents out

(* -------------------------------------------------------------------------- *)
(* Line classification                                                        *)
(* -------------------------------------------------------------------------- *)

let try_heading line =
  let len = String.length line in
  if len = 0 || line.[0] <> '#' then None
  else begin
    let level = ref 0 in
    while !level < len && line.[!level] = '#' do incr level done;
    if !level > 6 then None
    else if !level = len then Some (!level, "")
    else if line.[!level] = ' ' then
      Some (!level, String.sub line (!level + 1) (len - !level - 1))
    else None
  end

let try_code_fence line =
  if starts_with line "```" then
    let rest = String.sub line 3 (String.length line - 3) in
    let rest =
      if String.length rest > 0 && rest.[0] = ' ' then
        String.sub rest 1 (String.length rest - 1)
      else rest
    in
    Some rest
  else None

let try_list_item line =
  let len = String.length line in
  let check_prefix prefix =
    let plen = String.length prefix in
    if len >= plen && String.sub line 0 plen = prefix then
      Some (prefix, String.sub line plen (len - plen))
    else None
  in
  match check_prefix "- " with
  | Some _ as x -> x
  | None ->
    (match check_prefix "* " with
     | Some _ as x -> x
     | None ->
       (match check_prefix "+ " with
        | Some _ as x -> x
        | None ->
          (* ordered: "1. ", "12. ", ... *)
          let i = ref 0 in
          while !i < len && line.[!i] >= '0' && line.[!i] <= '9' do incr i done;
          if !i > 0 && !i + 1 < len && line.[!i] = '.' && line.[!i + 1] = ' '
          then
            Some (String.sub line 0 (!i + 2),
                  String.sub line (!i + 2) (len - !i - 2))
          else None))

let try_quote line =
  if starts_with line "> " then
    Some (String.sub line 2 (String.length line - 2))
  else if line = ">" then Some ""
  else None

(* -------------------------------------------------------------------------- *)
(* Line rendering (returns content without trailing newline)                  *)
(* -------------------------------------------------------------------------- *)

let render_normal_line line =
  match try_heading line with
  | Some (_level, content) -> wrap_heading content
  | None ->
    (match try_code_fence line with
     | Some _ -> wrap_code_line line
     | None ->
       (match try_list_item line with
        | Some (prefix, content) -> prefix ^ parse_inline content
        | None ->
          (match try_quote line with
           | Some content -> "> " ^ parse_inline content
           | None -> parse_inline line)))

(* -------------------------------------------------------------------------- *)
(* Push / flush                                                               *)
(* -------------------------------------------------------------------------- *)

let push (st : state) (chunk : string) : state * string =
  let buf_content = st.line_buf ^ chunk in
  let buf_len = String.length buf_content in
  let out_buf = Buffer.create (buf_len * 2 + 16) in
  let new_ctx = ref st.ctx in
  let rec loop pos =
    if pos >= buf_len then pos
    else
      match String.index_from_opt buf_content pos '\n' with
      | None -> pos
      | Some nl_pos ->
        let line = String.sub buf_content pos (nl_pos - pos) in
        (match !new_ctx with
         | InCodeBlock _ ->
           if try_code_fence line <> None then begin
             (* Closing fence *)
             Buffer.add_string out_buf (wrap_code_line line);
             Buffer.add_char out_buf '\n';
             new_ctx := Normal
           end else begin
             (* Code content line — render raw, no inline parsing *)
             Buffer.add_string out_buf (wrap_code_line line);
             Buffer.add_char out_buf '\n'
           end
         | Normal ->
           (match try_code_fence line with
            | Some lang ->
              (* Opening fence — enter code block *)
              new_ctx := InCodeBlock { lang };
              Buffer.add_string out_buf (wrap_code_line line);
              Buffer.add_char out_buf '\n'
            | None ->
              Buffer.add_string out_buf (render_normal_line line);
              Buffer.add_char out_buf '\n'));
        loop (nl_pos + 1)
  in
  let final_pos = loop 0 in
  let remainder = String.sub buf_content final_pos (buf_len - final_pos) in
  ({ ctx = !new_ctx; line_buf = remainder }, Buffer.contents out_buf)

let flush (st : state) : string =
  if st.line_buf = "" then ""
  else
    match st.ctx with
    | InCodeBlock _ -> wrap_code_line st.line_buf
    | Normal -> render_normal_line st.line_buf
