(* par_code_syntax — just enough highlighting for code blocks to read as code.

   Deliberately small: comments, strings, numbers and keywords, no parser. The
   output is ANSI text, the same shape the markdown layer already produces, so
   it flows through the existing renderer unchanged. Colours are the plain
   eight-colour set so they follow whatever palette the terminal uses; comments
   use bright black rather than the dim attribute, which notty does not have. *)

let esc = "\027["
let reset = esc ^ "0m"
let c_keyword = esc ^ "36m" (* cyan *)
let c_string = esc ^ "32m" (* green *)
let c_number = esc ^ "33m" (* yellow *)
let c_comment = esc ^ "90m" (* bright black *)

type family = Ml | Js | Py | Rs | Go | Sh | Json | Plain

let family_of (lang : string) : family =
  match String.lowercase_ascii (String.trim lang) with
  | "ocaml" | "ml" | "mli" -> Ml
  | "js" | "javascript" | "ts" | "typescript" | "json5" | "jsx" | "tsx" -> Js
  | "py" | "python" -> Py
  | "rs" | "rust" -> Rs
  | "go" | "golang" -> Go
  | "sh" | "bash" | "shell" | "zsh" | "console" -> Sh
  | "json" -> Json
  | _ -> Plain

let keywords (f : family) : string list =
  match f with
  | Ml ->
    [ "let"; "in"; "type"; "module"; "match"; "with"; "fun"; "function"; "val";
      "if"; "then"; "else"; "begin"; "end"; "and"; "rec"; "open"; "struct";
      "sig"; "mutable"; "when"; "exception"; "try"; "raise"; "as"; "of";
      "external"; "include"; "object"; "method"; "new"; "private" ]
  | Js ->
    [ "const"; "let"; "var"; "function"; "return"; "if"; "else"; "for"; "while";
      "class"; "new"; "import"; "from"; "export"; "default"; "await"; "async";
      "try"; "catch"; "finally"; "throw"; "typeof"; "instanceof"; "null";
      "undefined"; "true"; "false"; "switch"; "case"; "break"; "continue" ]
  | Py ->
    [ "def"; "class"; "return"; "if"; "elif"; "else"; "for"; "while"; "import";
      "from"; "as"; "with"; "try"; "except"; "finally"; "raise"; "lambda";
      "None"; "True"; "False"; "and"; "or"; "not"; "in"; "is"; "yield"; "pass" ]
  | Rs ->
    [ "fn"; "let"; "mut"; "struct"; "enum"; "impl"; "trait"; "pub"; "use";
      "mod"; "match"; "if"; "else"; "for"; "while"; "loop"; "return"; "self";
      "Self"; "Some"; "None"; "Ok"; "Err"; "where"; "async"; "await"; "move" ]
  | Go ->
    [ "func"; "var"; "const"; "type"; "struct"; "interface"; "package";
      "import"; "return"; "if"; "else"; "for"; "range"; "switch"; "case";
      "defer"; "go"; "chan"; "select"; "map"; "nil"; "true"; "false" ]
  | Sh ->
    [ "if"; "then"; "else"; "fi"; "for"; "do"; "done"; "while"; "case"; "esac";
      "function"; "return"; "export"; "local"; "set"; "unset"; "shift"; "echo" ]
  | Json | Plain -> []

let is_ident_char c =
  (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')
  || c = '_' || c = '\''

let is_digit c = c >= '0' && c <= '9'

let line_comment_prefix (f : family) : string list =
  match f with
  | Py | Sh -> [ "#" ]
  | Rs | Go | Js -> [ "//" ]
  | Ml -> [ "(*" ]
  | Json | Plain -> []

(* Render one line. [f] picks the keyword and comment vocabulary; the caller
   already knows it is inside a code block. *)
let highlight_line ~(family : family) (line : string) : string =
  let n = String.length line in
  let buf = Buffer.create (n + 32) in
  let keywords = keywords family in
  let comments = line_comment_prefix family in
  let starts_at p s =
    let m = String.length s in
    p + m <= n && String.sub line p m = s
  in
  let rec go i =
    if i >= n then ()
    else begin
      (* comment to end of line *)
      match List.find_opt (starts_at i) comments with
      | Some _ ->
        Buffer.add_string buf c_comment;
        Buffer.add_string buf (String.sub line i (n - i));
        Buffer.add_string buf reset
      | None ->
        let c = line.[i] in
        if c = '"' || (c = '\'' && family <> Ml) then begin
          let j = ref (i + 1) in
          while !j < n && (line.[!j] <> c || line.[!j - 1] = '\\') do incr j done;
          let stop = if !j < n then !j + 1 else n in
          Buffer.add_string buf c_string;
          Buffer.add_string buf (String.sub line i (stop - i));
          Buffer.add_string buf reset;
          go stop
        end
        else if is_digit c then begin
          let j = ref i in
          while
            !j < n
            && (is_digit line.[!j] || line.[!j] = '.' || line.[!j] = '_'
                || line.[!j] = 'x' || line.[!j] = 'e'
                || (line.[!j] >= 'a' && line.[!j] <= 'f'))
          do
            incr j
          done;
          Buffer.add_string buf c_number;
          Buffer.add_string buf (String.sub line i (!j - i));
          Buffer.add_string buf reset;
          go !j
        end
        else if is_ident_char c then begin
          let j = ref i in
          while !j < n && is_ident_char line.[!j] do incr j done;
          let word = String.sub line i (!j - i) in
          if List.mem word keywords then begin
            Buffer.add_string buf c_keyword;
            Buffer.add_string buf word;
            Buffer.add_string buf reset
          end
          else Buffer.add_string buf word;
          go !j
        end
        else begin
          Buffer.add_char buf c;
          go (i + 1)
        end
    end
  in
  go 0;
  Buffer.contents buf

let highlight_line ~lang line = highlight_line ~family:(family_of lang) line
