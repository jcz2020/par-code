(* test_par_code_ui.ml — Tests for par_code_ui primitives, composition,
   dimensions, style construction, backend, and layout. *)

open Par_code_ui

(* ── Composition laws ──────────────────────────────────────────────── *)

let left_id_hcat () =
  let x = text "hello" in
  Alcotest.(check int) "width" (width x) (width (empty <|> x));
  Alcotest.(check int) "height" (height x) (height (empty <|> x))

let right_id_hcat () =
  let x = text "hello" in
  Alcotest.(check int) "width" (width x) (width (x <|> empty));
  Alcotest.(check int) "height" (height x) (height (x <|> empty))

let left_id_vcat () =
  let x = text "hello" in
  Alcotest.(check int) "width" (width x) (width (empty <-> x));
  Alcotest.(check int) "height" (height x) (height (empty <-> x))

let right_id_vcat () =
  let x = text "hello" in
  Alcotest.(check int) "width" (width x) (width (x <-> empty));
  Alcotest.(check int) "height" (height x) (height (x <-> empty))

let associativity_hcat () =
  let a = text "ab" in
  let b = text "cd" in
  let c = text "ef" in
  let lhs = (a <|> b) <|> c in
  let rhs = a <|> (b <|> c) in
  Alcotest.(check int) "width" (width lhs) (width rhs);
  Alcotest.(check int) "height" (height lhs) (height rhs)

let vcat_empty () =
  let result = vcat [] in
  Alcotest.(check int) "width" 0 (width result);
  Alcotest.(check int) "height" 0 (height result)

let hcat_empty () =
  let result = hcat [] in
  Alcotest.(check int) "width" 0 (width result);
  Alcotest.(check int) "height" 0 (height result)

(* ── Dimensions ─────────────────────────────────────────────────────── *)

let width_text () =
  Alcotest.(check int) "width of hello" 5 (width (text "hello"))

let height_text () =
  Alcotest.(check int) "height of hello" 1 (height (text "hello"))

let width_vcat () =
  let x = text "hello" <-> text "world" in
  Alcotest.(check int) "width of stacked" 5 (width x)

let height_vcat () =
  let x = text "hello" <-> text "world" in
  Alcotest.(check int) "height of stacked" 2 (height x)

let width_hcat () =
  let x = text "hello" <|> text "world" in
  Alcotest.(check int) "width of hcat" 10 (width x);
  Alcotest.(check int) "height of hcat" 1 (height x)

let width_different_heights () =
  (* Vertical: shorter image padded; width = max *)
  let a = text "ab" <-> text "cdef" in
  Alcotest.(check int) "width" 4 (width a);
  Alcotest.(check int) "height" 2 (height a)

(* ── textf ──────────────────────────────────────────────────────────── *)

let textf_basic () =
  let img = textf "num=%d" 42 in
  Alcotest.(check int) "width" 6 (width img);
  Alcotest.(check int) "height" 1 (height img)

(* ── Style construction ─────────────────────────────────────────────── *)

let style_fg_bold () =
  let s = style ~fg:Red ~bold:true () in
  (match s.fg with
   | Some Red -> ()
   | _ -> Alcotest.fail "fg should be Red");
  Alcotest.(check bool) "bold" true s.bold;
  Alcotest.(check bool) "italic" false s.italic

let style_bg_italic () =
  let s = style ~bg:Green ~italic:true () in
  (match s.bg with
   | Some Green -> ()
   | _ -> Alcotest.fail "bg should be Green");
  Alcotest.(check bool) "italic" true s.italic;
  Alcotest.(check bool) "bold" false s.bold

let style_dim_reverse () =
  let s = style ~dim:true ~reverse:true () in
  Alcotest.(check bool) "dim" true s.dim;
  Alcotest.(check bool) "reverse" true s.reverse;
  Alcotest.(check bool) "underline" false s.underline

let style_bright_color () =
  let s = style ~fg:(Bright Red) () in
  match s.fg with
  | Some (Bright Red) -> ()
  | _ -> Alcotest.fail "fg should be Bright Red"

let style_palette_color () =
  let s = style ~fg:(Palette 200) () in
  match s.fg with
  | Some (Palette n) -> Alcotest.(check int) "palette" 200 n
  | _ -> Alcotest.fail "fg should be Palette 200"

let style_rgb_color () =
  let s = style ~fg:(Rgb (255, 0, 0)) () in
  match s.fg with
  | Some (Rgb (r, g, b)) ->
    Alcotest.(check int) "r" 255 r;
    Alcotest.(check int) "g" 0 g;
    Alcotest.(check int) "b" 0 b
  | _ -> Alcotest.fail "fg should be Rgb"

let no_style_defaults () =
  let s = no_style in
  Alcotest.(check bool) "fg is None" true (s.fg = None);
  Alcotest.(check bool) "bg is None" true (s.bg = None);
  Alcotest.(check bool) "bold" false s.bold;
  Alcotest.(check bool) "italic" false s.italic;
  Alcotest.(check bool) "underline" false s.underline;
  Alcotest.(check bool) "dim" false s.dim;
  Alcotest.(check bool) "reverse" false s.reverse

(* ── Backend ────────────────────────────────────────────────────────── *)

let backend_create () =
  let _b = create_backend () in ()

let backend_supports_color () =
  let b = create_backend () in
  let _ = supports_color b in ()

let backend_get_size () =
  let b = create_backend () in
  let (cols, rows) = get_size b in
  Alcotest.(check bool) "cols > 0" true (cols > 0);
  Alcotest.(check bool) "rows > 0" true (rows > 0)

let backend_close () =
  let b = create_backend () in
  close b

(* ── Layout ─────────────────────────────────────────────────────────── *)

let hpad_width () =
  let img = hpad 2 3 (text "hi") in
  Alcotest.(check int) "padded width" 7 (width img)

let hpad_height () =
  let img = hpad 2 3 (text "hi") in
  Alcotest.(check int) "height unchanged" 1 (height img)

let vpad_height () =
  let img = vpad 1 0 (text "hi") in
  Alcotest.(check int) "padded height" 2 (height img)

let vpad_width () =
  let img = vpad 1 0 (text "hi") in
  Alcotest.(check int) "width unchanged" 2 (width img)

let hsnap_left_width () =
  let img = hsnap ~align:`Left 10 (text "hi") in
  Alcotest.(check int) "snapped width" 10 (width img)

let hsnap_right_width () =
  let img = hsnap ~align:`Right 10 (text "hi") in
  Alcotest.(check int) "snapped width" 10 (width img)

let hsnap_center_width () =
  let img = hsnap ~align:`Center 10 (text "hi") in
  Alcotest.(check int) "snapped width" 10 (width img)

let hsnap_crop () =
  let img = hsnap ~align:`Left 3 (text "abcdef") in
  Alcotest.(check int) "cropped width" 3 (width img)

let vsnap_top_height () =
  let img = vsnap ~align:`Top 3 (text "hi") in
  Alcotest.(check int) "snapped height" 3 (height img)

let vsnap_crop () =
  let img = text "line1" <-> text "line2" <-> text "line3" in
  let cropped = vsnap ~align:`Top 2 img in
  Alcotest.(check int) "cropped height" 2 (height cropped)

(* ── Empty text ─────────────────────────────────────────────────────── *)

let text_empty_string () =
  let img = text "" in
  Alcotest.(check int) "width" 0 (width img);
  Alcotest.(check int) "height" 0 (height img)

(* ── Test runner ─────────────────────────────────────────────────────── *)

let () =
  Alcotest.run "par_code_ui"
    [ "composition", [
        Alcotest.test_case "left_id_hcat" `Quick left_id_hcat;
        Alcotest.test_case "right_id_hcat" `Quick right_id_hcat;
        Alcotest.test_case "left_id_vcat" `Quick left_id_vcat;
        Alcotest.test_case "right_id_vcat" `Quick right_id_vcat;
        Alcotest.test_case "associativity" `Quick associativity_hcat;
        Alcotest.test_case "vcat_empty" `Quick vcat_empty;
        Alcotest.test_case "hcat_empty" `Quick hcat_empty;
      ];
      "dimensions", [
        Alcotest.test_case "width_text" `Quick width_text;
        Alcotest.test_case "height_text" `Quick height_text;
        Alcotest.test_case "width_vcat" `Quick width_vcat;
        Alcotest.test_case "height_vcat" `Quick height_vcat;
        Alcotest.test_case "width_hcat" `Quick width_hcat;
        Alcotest.test_case "width_different_heights" `Quick width_different_heights;
      ];
      "textf", [
        Alcotest.test_case "basic" `Quick textf_basic;
      ];
      "style", [
        Alcotest.test_case "fg_bold" `Quick style_fg_bold;
        Alcotest.test_case "bg_italic" `Quick style_bg_italic;
        Alcotest.test_case "dim_reverse" `Quick style_dim_reverse;
        Alcotest.test_case "bright_color" `Quick style_bright_color;
        Alcotest.test_case "palette_color" `Quick style_palette_color;
        Alcotest.test_case "rgb_color" `Quick style_rgb_color;
        Alcotest.test_case "no_style" `Quick no_style_defaults;
      ];
      "backend", [
        Alcotest.test_case "create" `Quick backend_create;
        Alcotest.test_case "supports_color" `Quick backend_supports_color;
        Alcotest.test_case "get_size" `Quick backend_get_size;
        Alcotest.test_case "close" `Quick backend_close;
      ];
      "layout", [
        Alcotest.test_case "hpad_width" `Quick hpad_width;
        Alcotest.test_case "hpad_height" `Quick hpad_height;
        Alcotest.test_case "vpad_height" `Quick vpad_height;
        Alcotest.test_case "vpad_width" `Quick vpad_width;
        Alcotest.test_case "hsnap_left" `Quick hsnap_left_width;
        Alcotest.test_case "hsnap_right" `Quick hsnap_right_width;
        Alcotest.test_case "hsnap_center" `Quick hsnap_center_width;
        Alcotest.test_case "hsnap_crop" `Quick hsnap_crop;
        Alcotest.test_case "vsnap_top" `Quick vsnap_top_height;
        Alcotest.test_case "vsnap_crop" `Quick vsnap_crop;
      ];
      "empty", [
        Alcotest.test_case "text_empty_string" `Quick text_empty_string;
      ];
    ]
