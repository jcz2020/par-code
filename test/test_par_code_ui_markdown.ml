(* test_par_code_ui_markdown.ml — Tests for streaming markdown-to-ANSI renderer.
   Covers basic rendering, code blocks, state transitions, partial chunks,
   round-trip property, edge cases, list items, and headings. *)

let string_contains s sub =
  let len_s = String.length s in
  let len_sub = String.length sub in
  let rec search i =
    if i + len_sub > len_s then false
    else if String.sub s i len_sub = sub then true
    else search (i + 1)
  in
  len_sub = 0 || search 0

let push_all chunks =
  let final_state, acc =
    List.fold_left (fun (s, acc) chunk ->
      let s', out = Par_code_ui_markdown.push s chunk in
      s', acc ^ out
    ) (Par_code_ui_markdown.initial, "") chunks
  in
  acc ^ Par_code_ui_markdown.flush final_state

let whole_and_flush doc =
  let s, out = Par_code_ui_markdown.push Par_code_ui_markdown.initial doc in
  out ^ Par_code_ui_markdown.flush s

(* ── Basic rendering ────────────────────────────────────────────────── *)

let heading_h1 () =
  let s, out = Par_code_ui_markdown.push Par_code_ui_markdown.initial "# Hello" in
  let out = out ^ Par_code_ui_markdown.flush s in
  Alcotest.(check bool) "contains bold" true (string_contains out "\027[1m");
  Alcotest.(check bool) "contains cyan" true (string_contains out "\027[36m");
  Alcotest.(check bool) "contains Hello" true (string_contains out "Hello")

let bold_text () =
  let s, out = Par_code_ui_markdown.push Par_code_ui_markdown.initial "**bold**" in
  let out = out ^ Par_code_ui_markdown.flush s in
  Alcotest.(check bool) "contains bold ANSI" true (string_contains out "\027[1m");
  Alcotest.(check bool) "contains 'bold'" true (string_contains out "bold")

let italic_text () =
  let s, out = Par_code_ui_markdown.push Par_code_ui_markdown.initial "_italic_" in
  let out = out ^ Par_code_ui_markdown.flush s in
  Alcotest.(check bool) "contains italic ANSI" true (string_contains out "\027[3m");
  Alcotest.(check bool) "contains 'italic'" true (string_contains out "italic")

let inline_code () =
  let s, out = Par_code_ui_markdown.push Par_code_ui_markdown.initial "`code`" in
  let out = out ^ Par_code_ui_markdown.flush s in
  Alcotest.(check bool) "contains dim" true (string_contains out "\027[2m");
  Alcotest.(check bool) "contains reverse" true (string_contains out "\027[7m");
  Alcotest.(check bool) "contains 'code'" true (string_contains out "code")

let link_text () =
  let s, out = Par_code_ui_markdown.push Par_code_ui_markdown.initial "[text](url)" in
  let out = out ^ Par_code_ui_markdown.flush s in
  Alcotest.(check bool) "contains underline" true (string_contains out "\027[4m");
  Alcotest.(check bool) "contains 'text'" true (string_contains out "text");
  Alcotest.(check bool) "contains dim for url" true (string_contains out "\027[2m");
  Alcotest.(check bool) "contains 'url'" true (string_contains out "url")

let double_underscore_bold () =
  let s, out = Par_code_ui_markdown.push Par_code_ui_markdown.initial "__bold__" in
  let out = out ^ Par_code_ui_markdown.flush s in
  Alcotest.(check bool) "contains bold ANSI" true (string_contains out "\027[1m");
  Alcotest.(check bool) "contains 'bold'" true (string_contains out "bold")

(* ── Code blocks ────────────────────────────────────────────────────── *)

let code_block () =
  let input = "```ocaml\nlet x = 1\n```" in
  let s, out = Par_code_ui_markdown.push Par_code_ui_markdown.initial input in
  let out = out ^ Par_code_ui_markdown.flush s in
  Alcotest.(check bool) "contains dim for code" true (string_contains out "\027[2m");
  Alcotest.(check bool) "contains 'let x = 1'" true (string_contains out "let x = 1")

let unclosed_code_block () =
  let s, out = Par_code_ui_markdown.push Par_code_ui_markdown.initial "```ocaml" in
  let out = out ^ Par_code_ui_markdown.flush s in
  Alcotest.(check bool) "contains dim" true (string_contains out "\027[2m");
  Alcotest.(check bool) "contains '```ocaml'" true (string_contains out "```ocaml")

let code_block_content_not_parsed () =
  let s, out = Par_code_ui_markdown.push Par_code_ui_markdown.initial
      "```ocaml\n**not bold**\n```" in
  let out = out ^ Par_code_ui_markdown.flush s in
  Alcotest.(check bool) "contains '**not bold**' literally"
    true (string_contains out "**not bold**")

let opening_fence_rendered () =
  let s, out = Par_code_ui_markdown.push Par_code_ui_markdown.initial "```\n" in
  let out = out ^ Par_code_ui_markdown.flush s in
  Alcotest.(check bool) "opening fence has dim" true (string_contains out "\027[2m")

let closing_fence_rendered () =
  let s, out = Par_code_ui_markdown.push Par_code_ui_markdown.initial "```\nhello\n```\n" in
  let out = out ^ Par_code_ui_markdown.flush s in
  Alcotest.(check bool) "closing fence has dim" true (string_contains out "\027[2m");
  Alcotest.(check bool) "contains 'hello'" true (string_contains out "hello")

(* ── State transitions ──────────────────────────────────────────────── *)

let enter_code_block_on_fence () =
  let s1, _ = Par_code_ui_markdown.push Par_code_ui_markdown.initial "```oc\n" in
  let s2, out2 = Par_code_ui_markdown.push s1 "code line\n" in
  let _s3, out3 = Par_code_ui_markdown.push s2 "```\n" in
  Alcotest.(check bool) "code line has dim" true (string_contains out2 "\027[2m");
  Alcotest.(check bool) "closing fence has dim" true (string_contains out3 "\027[2m")

let back_to_normal_after_close () =
  let s, _ = Par_code_ui_markdown.push Par_code_ui_markdown.initial "```\n" in
  let s2, _ = Par_code_ui_markdown.push s "code\n" in
  let s3, _ = Par_code_ui_markdown.push s2 "```\n" in
  let _s4, out4 = Par_code_ui_markdown.push s3 "**bold**\n" in
  Alcotest.(check bool) "after close, bold is parsed" true
    (string_contains out4 "\027[1m")

(* ── Partial chunks ─────────────────────────────────────────────────── *)

let partial_bold () =
  let s1, _ = Par_code_ui_markdown.push Par_code_ui_markdown.initial "**bo" in
  let s2, out = Par_code_ui_markdown.push s1 "ld**" in
  let out = out ^ Par_code_ui_markdown.flush s2 in
  Alcotest.(check bool) "contains bold ANSI" true (string_contains out "\027[1m");
  Alcotest.(check bool) "contains 'bold'" true (string_contains out "bold")

let partial_code_block () =
  let s1, _ = Par_code_ui_markdown.push Par_code_ui_markdown.initial "```oc" in
  let s2, _ = Par_code_ui_markdown.push s1 "aml\nlet x" in
  let s3, out = Par_code_ui_markdown.push s2 " = 1\n```" in
  let out = out ^ Par_code_ui_markdown.flush s3 in
  Alcotest.(check bool) "contains dim" true (string_contains out "\027[2m");
  Alcotest.(check bool) "contains 'let x = 1'" true (string_contains out "let x = 1")

let partial_heading () =
  let s1, _ = Par_code_ui_markdown.push Par_code_ui_markdown.initial "# Hel" in
  let s2, out = Par_code_ui_markdown.push s1 "lo\n" in
  let out = out ^ Par_code_ui_markdown.flush s2 in
  Alcotest.(check bool) "heading has bold" true (string_contains out "\027[1m");
  Alcotest.(check bool) "heading has cyan" true (string_contains out "\027[36m")

let partial_link () =
  let s1, _ = Par_code_ui_markdown.push Par_code_ui_markdown.initial "[te" in
  let s2, out = Par_code_ui_markdown.push s1 "xt](url)" in
  let out = out ^ Par_code_ui_markdown.flush s2 in
  Alcotest.(check bool) "underline for link text" true (string_contains out "\027[4m")

(* ── Round-trip property ────────────────────────────────────────────── *)

let round_trip_whole_vs_chunked () =
  let doc = "# Hello\n\nThis is **bold** and _italic_.\n\n```ocaml\nlet x = 1\n```\n" in
  let whole_output = whole_and_flush doc in
  let chunks = [ "# Hel"; "lo\n\n"; "This is "; "**bold**"; " and _italic_.\n\n";
                 "```ocaml\n"; "let x = 1\n"; "```\n" ] in
  let chunked_output = push_all chunks in
  Alcotest.(check string) "round_trip_chunked_equals_whole" whole_output chunked_output

let round_trip_one_char () =
  let doc = "Hello **world**" in
  let whole_output = whole_and_flush doc in
  let chunks = List.init (String.length doc) (fun i -> String.sub doc i 1) in
  let chunked_output = push_all chunks in
  Alcotest.(check string) "one_char_chunked" whole_output chunked_output

let round_trip_line_level () =
  let doc = "# Hello\n**bold**\n" in
  let whole_output = whole_and_flush doc in
  let chunks = [ "# Hello\n"; "**bold**\n" ] in
  let chunked_output = push_all chunks in
  Alcotest.(check string) "line_level" whole_output chunked_output

let round_trip_word_level () =
  let doc = "# Hello **world** and _italic_" in
  let whole_output = whole_and_flush doc in
  let chunks = [ "# "; "Hello "; "**world**"; " and "; "_italic_" ] in
  let chunked_output = push_all chunks in
  Alcotest.(check string) "word_level" whole_output chunked_output

(* ── Edge cases ─────────────────────────────────────────────────────── *)

let empty_input () =
  let out = Par_code_ui_markdown.flush Par_code_ui_markdown.initial in
  Alcotest.(check string) "empty flush" "" out

let plain_text_no_markdown () =
  let s, out = Par_code_ui_markdown.push Par_code_ui_markdown.initial "hello world" in
  let out = out ^ Par_code_ui_markdown.flush s in
  Alcotest.(check string) "plain text" "hello world" out;
  Alcotest.(check bool) "no ANSI escapes" false (string_contains out "\027")

let unclosed_bold_literal () =
  let s, out = Par_code_ui_markdown.push Par_code_ui_markdown.initial "**bold" in
  let out = out ^ Par_code_ui_markdown.flush s in
  Alcotest.(check string) "literal **bold" "**bold" out

let unclosed_italic_literal () =
  let s, out = Par_code_ui_markdown.push Par_code_ui_markdown.initial "_italic" in
  let out = out ^ Par_code_ui_markdown.flush s in
  Alcotest.(check string) "literal _italic" "_italic" out

let nested_bold_italic () =
  let s, out = Par_code_ui_markdown.push Par_code_ui_markdown.initial
      "**bold *italic* bold**" in
  let out = out ^ Par_code_ui_markdown.flush s in
  Alcotest.(check bool) "contains bold" true (string_contains out "\027[1m");
  Alcotest.(check bool) "inner *italic* is literal" true (string_contains out "*italic*")

let reset_is_noop () =
  Par_code_ui_markdown.reset ()

(* ── List items ─────────────────────────────────────────────────────── *)

let unordered_list () =
  let s, out = Par_code_ui_markdown.push Par_code_ui_markdown.initial "- item" in
  let out = out ^ Par_code_ui_markdown.flush s in
  Alcotest.(check bool) "preserves '- '" true (string_contains out "- ");
  Alcotest.(check bool) "contains 'item'" true (string_contains out "item")

let ordered_list () =
  let s, out = Par_code_ui_markdown.push Par_code_ui_markdown.initial "1. ordered" in
  let out = out ^ Par_code_ui_markdown.flush s in
  Alcotest.(check bool) "preserves '1. '" true (string_contains out "1. ");
  Alcotest.(check bool) "contains 'ordered'" true (string_contains out "ordered")

let list_inline_parsed () =
  let s, out = Par_code_ui_markdown.push Par_code_ui_markdown.initial "- **bold** item" in
  let out = out ^ Par_code_ui_markdown.flush s in
  Alcotest.(check bool) "bold inside list" true (string_contains out "\027[1m");
  Alcotest.(check bool) "preserves '- '" true (string_contains out "- ")

let asterisk_list () =
  let s, out = Par_code_ui_markdown.push Par_code_ui_markdown.initial "* item" in
  let out = out ^ Par_code_ui_markdown.flush s in
  Alcotest.(check bool) "preserves '* '" true (string_contains out "* ");
  Alcotest.(check bool) "contains 'item'" true (string_contains out "item")

let plus_list () =
  let s, out = Par_code_ui_markdown.push Par_code_ui_markdown.initial "+ item" in
  let out = out ^ Par_code_ui_markdown.flush s in
  Alcotest.(check bool) "preserves '+ '" true (string_contains out "+ ")

(* ── Headings ───────────────────────────────────────────────────────── *)

let heading_h1_styled () =
  let s, out = Par_code_ui_markdown.push Par_code_ui_markdown.initial "# H1" in
  let out = out ^ Par_code_ui_markdown.flush s in
  Alcotest.(check bool) "bold" true (string_contains out "\027[1m");
  Alcotest.(check bool) "cyan" true (string_contains out "\027[36m");
  Alcotest.(check bool) "contains H1" true (string_contains out "H1")

let heading_h6 () =
  let s, out = Par_code_ui_markdown.push Par_code_ui_markdown.initial "###### H6" in
  let out = out ^ Par_code_ui_markdown.flush s in
  Alcotest.(check bool) "bold" true (string_contains out "\027[1m");
  Alcotest.(check bool) "contains H6" true (string_contains out "H6")

let seven_hashes_not_heading () =
  let s, out = Par_code_ui_markdown.push Par_code_ui_markdown.initial
      "####### Not heading" in
  let out = out ^ Par_code_ui_markdown.flush s in
  Alcotest.(check bool) "no bold (not a heading)" false (string_contains out "\027[1m");
  Alcotest.(check bool) "contains text" true (string_contains out "####### Not heading")

let heading_inline_parsed () =
  let s, out = Par_code_ui_markdown.push Par_code_ui_markdown.initial "# **bold** title" in
  let out = out ^ Par_code_ui_markdown.flush s in
  Alcotest.(check bool) "heading cyan" true (string_contains out "\027[36m");
  Alcotest.(check bool) "bold inside heading" true (string_contains out "\027[1m")

(* ── Quote ──────────────────────────────────────────────────────────── *)

let blockquote () =
  let s, out = Par_code_ui_markdown.push Par_code_ui_markdown.initial "> quoted" in
  let out = out ^ Par_code_ui_markdown.flush s in
  Alcotest.(check bool) "preserves '> '" true (string_contains out "> ");
  Alcotest.(check bool) "contains 'quoted'" true (string_contains out "quoted")

(* ── Test runner ─────────────────────────────────────────────────────── *)

let () =
  Alcotest.run "par_code_ui_markdown"
    [ "basic", [
        Alcotest.test_case "heading_h1" `Quick heading_h1;
        Alcotest.test_case "bold" `Quick bold_text;
        Alcotest.test_case "italic" `Quick italic_text;
        Alcotest.test_case "inline_code" `Quick inline_code;
        Alcotest.test_case "link" `Quick link_text;
        Alcotest.test_case "double_underscore_bold" `Quick double_underscore_bold;
      ];
      "code_blocks", [
        Alcotest.test_case "fenced" `Quick code_block;
        Alcotest.test_case "unclosed" `Quick unclosed_code_block;
        Alcotest.test_case "content_not_parsed" `Quick code_block_content_not_parsed;
        Alcotest.test_case "opening_fence" `Quick opening_fence_rendered;
        Alcotest.test_case "closing_fence" `Quick closing_fence_rendered;
      ];
      "state_transitions", [
        Alcotest.test_case "enter_code_block" `Quick enter_code_block_on_fence;
        Alcotest.test_case "back_to_normal" `Quick back_to_normal_after_close;
      ];
      "partial", [
        Alcotest.test_case "bold" `Quick partial_bold;
        Alcotest.test_case "code_block" `Quick partial_code_block;
        Alcotest.test_case "heading" `Quick partial_heading;
        Alcotest.test_case "link" `Quick partial_link;
      ];
      "round_trip", [
        Alcotest.test_case "whole_vs_chunked" `Quick round_trip_whole_vs_chunked;
        Alcotest.test_case "one_char" `Quick round_trip_one_char;
        Alcotest.test_case "line_level" `Quick round_trip_line_level;
        Alcotest.test_case "word_level" `Quick round_trip_word_level;
      ];
      "edge_cases", [
        Alcotest.test_case "empty_input" `Quick empty_input;
        Alcotest.test_case "plain_text" `Quick plain_text_no_markdown;
        Alcotest.test_case "unclosed_bold" `Quick unclosed_bold_literal;
        Alcotest.test_case "unclosed_italic" `Quick unclosed_italic_literal;
        Alcotest.test_case "nested_bold_italic" `Quick nested_bold_italic;
        Alcotest.test_case "reset_noop" `Quick reset_is_noop;
      ];
      "lists", [
        Alcotest.test_case "unordered" `Quick unordered_list;
        Alcotest.test_case "ordered" `Quick ordered_list;
        Alcotest.test_case "inline_parsed" `Quick list_inline_parsed;
        Alcotest.test_case "asterisk" `Quick asterisk_list;
        Alcotest.test_case "plus" `Quick plus_list;
      ];
      "headings", [
        Alcotest.test_case "h1" `Quick heading_h1_styled;
        Alcotest.test_case "h6" `Quick heading_h6;
        Alcotest.test_case "seven_hashes" `Quick seven_hashes_not_heading;
        Alcotest.test_case "inline_parsed" `Quick heading_inline_parsed;
      ];
      "quotes", [
        Alcotest.test_case "blockquote" `Quick blockquote;
      ];
    ]
