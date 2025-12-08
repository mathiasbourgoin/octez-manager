open Rresult
open Octez_manager_lib
module Keys = Miaou.Core.Keys
module Widgets = Miaou_widgets_display.Widgets

let ( let* ) = Result.bind

(* Structured representation of a CLI option extracted from --help output. *)
type value_kind =
  | Addr_port
  | Port
  | Addr
  | File
  | Dir
  | Path
  | Number
  | Float
  | Text

type arg_kind = Toggle | Value of value_kind

type option_entry =
  {names : string list; arg : string option; doc : string; kind : arg_kind}

(* Mutable selection entry used inside the modal. *)
type row = {
  opt : option_entry;
  mutable value : string option;
  mutable selected : bool;
}

let cache : (string, option_entry list) Hashtbl.t = Hashtbl.create 3

let primary_name names =
  match
    List.find_opt
      (fun n -> String.length n > 2 && String.sub n 0 2 = "--")
      names
  with
  | Some long -> long
  | None -> ( match names with h :: _ -> h | [] -> "")

let trim_nonempty s =
  let t = String.trim s in
  if t = "" then None else Some t

let contains ~needle haystack =
  let nlen = String.length needle in
  let hlen = String.length haystack in
  let rec loop i =
    if i + nlen > hlen then false
    else if String.sub haystack i nlen = needle then true
    else loop (i + 1)
  in
  if nlen = 0 then true else loop 0

let classify_arg_kind ~names ~arg ~doc =
  match arg with
  | None -> Toggle
  | Some placeholder ->
      let text =
        String.concat " "
          [ String.lowercase_ascii placeholder;
            String.lowercase_ascii doc;
            String.concat " " (List.map String.lowercase_ascii names) ]
      in
      let has s = contains ~needle:(String.lowercase_ascii s) text in
      if has "addr:port" || has "address:port" then Value Addr_port
      else if has "port" then Value Port
      else if has "addr" || has "address" || has "host" then Value Addr
      else if has "file" then Value File
      else if has "dir" || has "directory" then Value Dir
      else if has "path" then Value Path
      else if has "mode" then Value Text
      else if has "float" then Value Float
      else if has "int" || has "num" || has "number" then Value Number
      else Value Text

let split_spec_doc raw_line =
  let line = String.trim raw_line in
  let len = String.length line in
  let rec find_gap idx =
    if idx >= len - 1 then None
    else if line.[idx] = '\t' then Some idx
    else if line.[idx] = ' ' && line.[idx + 1] = ' ' then Some idx
    else find_gap (idx + 1)
  in
  match find_gap 0 with
  | Some idx ->
      let gap = if line.[idx] = '\t' then 1 else 2 in
      ( String.sub line 0 idx |> String.trim,
        String.sub line (idx + gap) (len - (idx + gap)) |> String.trim )
  | None -> (String.trim line, "")

let clean_placeholder s =
  let trimmed = String.trim s in
  let len = String.length trimmed in
  if len = 0 then ""
  else
    let rec drop_trailing i =
      if i <= 0 then 0
      else
        match trimmed.[i - 1] with
        | ',' | ';' | ')' -> drop_trailing (i - 1)
        | _ -> i
    in
    let stop = drop_trailing len in
    String.sub trimmed 0 stop

let parse_spec spec =
  let tokens =
    spec |> String.split_on_char ' '
    |> List.filter (fun s -> String.trim s <> "")
  in
  let names, arg_tokens =
    List.fold_left
      (fun (names, args) tok ->
        let tok = String.trim tok in
        if tok = "," then (names, args)
        else if String.length tok > 0 && tok.[0] = '-' then
          let name, inline_arg =
            match String.index_opt tok '=' with
            | None -> (tok, None)
            | Some idx ->
                let name = String.sub tok 0 idx in
                let placeholder = String.sub tok (idx + 1) (String.length tok - idx - 1) in
                (name, Some placeholder)
          in
          (name :: names, (match inline_arg with None -> args | Some a -> a :: args))
        else (names, tok :: args))
      ([], [])
      tokens
  in
  let arg =
    match List.rev arg_tokens |> List.filter_map trim_nonempty with
    | [] -> None
    | x :: _ -> Some (clean_placeholder x)
  in
  (List.rev names, arg)

let is_option_line line =
  let trimmed = String.trim line in
  trimmed <> "" && trimmed.[0] = '-'

let strip_ansi s =
  let len = String.length s in
  let buf = Buffer.create len in
  let rec skip_escape i =
    if i >= len then len
    else
      match s.[i] with
      | 'A' .. 'Z' | 'a' .. 'z' -> i + 1
      | _ -> skip_escape (i + 1)
  in
  let rec loop i =
    if i >= len then ()
    else if s.[i] = '\027' then
      let next =
        if i + 1 < len && s.[i + 1] = '[' then skip_escape (i + 2)
        else skip_escape (i + 1)
      in
      loop next
    else (
      Buffer.add_char buf s.[i] ;
      loop (i + 1))
  in
  loop 0 ;
  Buffer.contents buf

let parse_help output =
  let lines = String.split_on_char '\n' output in
  let finalize current acc =
    match current with None -> acc | Some r -> r :: acc
  in
  let rec loop acc current = function
    | [] -> List.rev (finalize current acc)
    | line :: rest when is_option_line line ->
        let acc = finalize current acc in
        let spec, doc = split_spec_doc line in
        let names, arg = parse_spec spec in
        let kind = classify_arg_kind ~names ~arg ~doc in
        let entry = {names; arg; doc; kind} in
        loop acc (Some entry) rest
    | line :: rest ->
        let trimmed = String.trim line in
        if trimmed = "" then loop acc current rest
        else
          let current =
            match current with
            | None -> None
            | Some opt ->
                let doc =
                  if opt.doc = "" then trimmed else opt.doc ^ " " ^ trimmed
                in
                let kind = classify_arg_kind ~names:opt.names ~arg:opt.arg ~doc in
                Some {opt with doc; kind}
          in
          loop acc current rest
  in
  loop [] None lines

let run_help binary =
  if not (Sys.file_exists binary) then
    Error (`Msg (Printf.sprintf "Binary not found at %s" binary))
  else
    Common.run_out
      [
        "env";
        "MANPAGER=cat";
        "PAGER=cat";
        "TERM=dumb";
        binary;
        "run";
        "--help=plain";
      ]

let load_options ~binary =
  match Hashtbl.find_opt cache binary with
  | Some opts -> Ok opts
  | None ->
      let* output = run_help binary in
      let output = strip_ansi output in
      let opts = parse_help output in
      if opts = [] then Error (`Msg "No options parsed from help output")
      else (
        Hashtbl.replace cache binary opts ;
        Ok opts)

let render_value = function None -> "" | Some v -> v

let truncate ~max_len s =
  if String.length s <= max_len then s else String.sub s 0 (max_len - 1) ^ "…"

let option_label entry = String.concat ", " entry.names

let wrap_text ~width s =
  let wrap_line s =
    let len = String.length s in
    if len <= width then [s]
    else
      let rec aux start acc =
        if start >= len then List.rev acc
        else
          let remaining = len - start in
          if remaining <= width then
            List.rev (String.sub s start remaining :: acc)
          else
            let limit = start + width in
            let end_ =
              try
                let last_space = String.rindex_from s limit ' ' in
                if last_space > start then last_space else limit
              with _ -> limit
            in
            let sub = String.sub s start (end_ - start) in
            let next_start =
              if end_ < len && s.[end_] = ' ' then end_ + 1 else end_
            in
            aux next_start (sub :: acc)
      in
      aux 0 []
  in
  String.split_on_char '\n' s |> List.concat_map wrap_line

let format_tokens rows =
  rows
  |> List.filter (fun r -> r.selected)
  |> List.concat_map (fun r ->
      let flag = primary_name r.opt.names in
      match r.value with None -> [flag] | Some v -> [flag ^ "=" ^ v])

let open_modal ~title ~options ~on_apply =
  let rows =
    Array.of_list
      (List.map (fun opt -> {opt; value = None; selected = false}) options)
  in
  let module Modal = struct
    type state = {rows : row array; mutable cursor : int}

    type msg = unit

    let init () = {rows; cursor = 0}

    let update s _ = s

    let refresh s = s

    let move s delta =
      let len = Array.length s.rows in
      let next = max 0 (min (len - 1) (s.cursor + delta)) in
      s.cursor <- next ;
      s

    let current_row s =
      if Array.length s.rows = 0 then None else Some s.rows.(s.cursor)

    let toggle s =
      match current_row s with
      | None -> ()
      | Some row -> row.selected <- not row.selected

    let edit_value s =
      match current_row s with
      | None -> ()
      | Some row -> (
          match row.opt.arg with
          | None -> toggle s
          | Some placeholder ->
              Modal_helpers.prompt_text_modal
                ~title:(option_label row.opt)
                ~placeholder:(Some placeholder)
                ~initial:(render_value row.value)
                ~on_submit:(fun v ->
                  let v = String.trim v in
                  if v = "" then (
                    row.value <- None ;
                    row.selected <- false)
                  else (
                    row.value <- Some v ;
                    row.selected <- true))
                ())

    let show_hint s =
      match current_row s with
      | None -> ()
      | Some row ->
          let lines = wrap_text ~width:72 row.opt.doc in
          Modal_helpers.open_text_modal
            ~title:(option_label row.opt)
            ~lines:("Option details" :: "" :: lines)

    let apply_and_close s =
      let tokens = s.rows |> Array.to_list |> format_tokens in
      on_apply tokens ;
      Miaou.Core.Modal_manager.close_top `Commit

    let view s ~focus:_ ~size =
      let width = size.LTerm_geom.cols in
      let opt_width = max 18 (min 40 (width / 2)) in
      let arg_width = max 10 (min 24 (width / 3)) in
      let value_width = max 8 (width - opt_width - arg_width - 12) in
      let doc_width = max 20 (width - 8) in
      let render_row idx row =
        let marker = if idx = s.cursor then Widgets.bold "➤" else " " in
        let checkbox = if row.selected then "●" else "○" in
        let opt = truncate ~max_len:opt_width (option_label row.opt) in
        let arg =
          truncate ~max_len:arg_width (Option.value ~default:"" row.opt.arg)
        in
        let value =
          match row.value with
          | None -> ""
          | Some v ->
              let trimmed = truncate ~max_len:value_width v in
              Printf.sprintf "[%s]" trimmed
        in
        let header =
          Printf.sprintf
            "%s %s %-*s %-*s %s"
            marker
            checkbox
            opt_width
            opt
            arg_width
            arg
            value
        in
        let doc_lines =
          row.opt.doc |> wrap_text ~width:doc_width
          |> List.map (fun l -> "    " ^ l)
        in
        (header :: doc_lines) @ [""]
      in
      let body =
        s.rows |> Array.to_list
        |> List.mapi (fun idx row -> render_row idx row)
        |> List.concat |> String.concat "\n"
      in
      let hint_line =
        match current_row s with
        | None -> Widgets.dim "Select an option to view details"
        | Some row -> truncate ~max_len:(max 20 (width - 10)) row.opt.doc
      in
      let footer =
        [
          Widgets.dim
            "↑/↓ move  Enter edit/toggle  Space toggle  s apply  ? hint  Esc \
             close";
          Widgets.dim hint_line;
        ]
      in
      Miaou_widgets_layout.Vsection.render
        ~size
        ~header:[Widgets.title_highlight title; ""]
        ~footer
        ~child:(fun _ -> body)

    let handle_modal_key s key ~size:_ =
      match Keys.of_string key with
      | Some Keys.Up -> move s (-1)
      | Some Keys.Down -> move s 1
      | Some Keys.Enter ->
          edit_value s ;
          s
      | Some (Keys.Char " ") ->
          toggle s ;
          s
      | Some (Keys.Char "s") | Some (Keys.Char "S") ->
          apply_and_close s ;
          s
      | Some (Keys.Char "?") ->
          show_hint s ;
          s
      | Some (Keys.Char "Esc") | Some (Keys.Char "q") | Some (Keys.Char "Q") ->
          Miaou.Core.Modal_manager.close_top `Cancel ;
          s
      | _ -> s

    let handle_key = handle_modal_key

    let enter s = s

    let service_select s _ = s

    let service_cycle s _ = s

    let back s = s

    let keymap _ = []

    let next_page _ = None

    let has_modal _ = true
  end in
  let ui : Miaou.Core.Modal_manager.ui =
    {title; left = None; max_width = Some 96; dim_background = true}
  in
  Miaou.Core.Modal_manager.push_default
    (module Modal)
    ~init:(Modal.init ())
    ~ui
    ~on_close:(fun _ _ -> ())

let open_node_run_help ~app_bin_dir ~on_apply =
  let app_bin_dir = String.trim app_bin_dir in
  if app_bin_dir = "" then
    Modal_helpers.show_error ~title:"Node Flags" "Octez bin directory is empty"
  else
    let binary = Filename.concat app_bin_dir "octez-node" in
    match load_options ~binary with
    | Ok options -> open_modal ~title:"Node Flags" ~options ~on_apply
    | Error (`Msg msg) -> Modal_helpers.show_error ~title:"Node Flags" msg

module For_tests = struct
  let parse_help = parse_help
  let arg_kind_to_string = function
    | Toggle -> "toggle"
    | Value Addr_port -> "addr_port"
    | Value Port -> "port"
    | Value Addr -> "addr"
    | Value File -> "file"
    | Value Dir -> "dir"
    | Value Path -> "path"
    | Value Number -> "number"
    | Value Float -> "float"
    | Value Text -> "text"
end
