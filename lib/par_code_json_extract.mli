(* par_code_json_extract.mli — shared lax JSON-object extraction. *)

val extract_object : string -> string option
(** [extract_object s] is the first balanced `{...}` span in [s], or [None].
    Both the judge and the selector parse model output through this function so
    their tolerance for surrounding prose stays identical. *)
