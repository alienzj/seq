(* 786 *)

open Core
open Err

module T = ANSITerminal

module rec SeqS: Intf.StmtIntf = Stmt.StmtParser (SeqE)
       and SeqE: Intf.ExprIntf = Expr.ExprParser (SeqS) 

let rec parse_string ?fname ?debug ctx code =
  let fname = Option.value fname ~default:"" in
  let lexbuf = Lexing.from_string (code ^ "\n") in
  try
    let state = Lexer.stack_create fname in
    let ast = Parser.program (Lexer.token state) lexbuf in
    (* dbg "|> AST of \n%s ==> " code; *)
    (* dbg "%s" @@ Seq_ast.prn_ast ast; *)
    SeqS.parse_module ctx ast
  with
  | Lexer.SyntaxError(msg, pos) ->
    raise @@ CompilerError(Lexer(msg), [pos])
  | Parser.Error ->
    let pos = Ast.Pos.
      { file = fname;
        line = lexbuf.lex_start_p.pos_lnum;
        col = lexbuf.lex_start_p.pos_cnum - lexbuf.lex_start_p.pos_bol;
        len = 0 } 
    in
    raise @@ CompilerError(Parser, [pos])
  | SeqCamlError(msg, pos) ->
    Printexc.print_backtrace stderr;
    raise @@ CompilerError(Descent(msg), pos)
  | SeqCError(msg, pos) ->
    raise @@ CompilerError(Compiler(msg), [pos])

and parse_file ?debug ctx file =
  Util.dbg "parsing %s" file;
  let lines = In_channel.read_lines file in
  let code = (String.concat ~sep:"\n" lines) ^ "\n" in
  parse_string ?debug ~fname:(Filename.realpath file) ctx code

let init file error_handler =
  let mdl = Llvm.Module.init () in
  let ctx = Ctx.init 
    (Filename.realpath file) 
    mdl mdl 
    (Llvm.Module.block mdl) 
    parse_file 
  in
  try
    let args = Llvm.Module.get_args mdl in
    Ctx.add ctx "__argv__" (Ctx.var ctx args);

    let seqpath = Option.value (Sys.getenv "SEQ_PATH") ~default:"" in
    let stdlib_path = sprintf "%s/stdlib.seq" seqpath in
    ctx.parse_file ctx stdlib_path;

    ctx.parse_file ctx file;
    Some mdl
  with CompilerError(typ, pos) ->
    Ctx.dump ctx;
    error_handler typ pos;
    None

let parse_c fname =
  let error_handler typ (pos: Ast.Pos.t list) =
    let Ast.Pos.{ file; line; col; len } = List.hd_exn pos in
    let msg = match typ with
      | Lexer s -> s
      | Parser -> "parsing error"
      | Descent s -> s
      | Compiler s -> s 
    in
    Ctypes.(Foreign.foreign "caml_error_callback"
      (string @-> int @-> int @-> string @-> returning void)) 
      msg line col file
  in
  let seq_module = init fname error_handler in
  match seq_module with
  | Some seq_module -> 
    Ctypes.raw_address_of_ptr (Ctypes.to_voidp seq_module)
  | None -> 
    Nativeint.zero

let () =
  let _ = Callback.register "parse_c" parse_c in

  if Array.length Sys.argv >= 2 then
    try
      let err_handler = fun a b -> raise @@ CompilerError(a, b) in
      let m = init Sys.argv.(1) err_handler in
      match m with
      | Some m -> 
        begin try
          Llvm.Module.exec m (Array.to_list Sys.argv) false
        with SeqCError(msg, pos) -> 
          raise @@ CompilerError(Compiler(msg), [pos])
        end
      | None -> raise 
        Caml.Not_found
    with CompilerError (typ, pos_lst) as err ->
      let kind, msg = match typ with
        | Lexer s -> "lexer", s
        | Parser -> "parser", "Parsing error"
        | Descent s -> "descent", s
        | Compiler s -> "compiler", s 
      in
      let file_line file line =
        if String.length file > 0 && file.[0] <> '<' then
          try
            let lines = In_channel.read_lines file in 
            List.nth lines (line - 1)
          with _ -> 
            None
        else None 
      in
      let style = [T.Bold; T.red] in
      eprintf "%s%!" @@ T.sprintf style "[ERROR] %s error: %s\n" kind msg;
      List.iteri pos_lst ~f:(fun i pos ->
        let Ast.Pos.{ file; line; col; len } = pos in
        match file_line file line with
        | Some file_line  ->
          let pre = if i = 0 then "" else "then in\n        " in 
          eprintf "%s%!" @@ T.sprintf style "        %s%s: %d,%d\n" 
            pre file line col;
          eprintf "%s%!" @@ T.sprintf style "   %3d: %s" 
            line (String.prefix file_line col);
          eprintf "%s%!" @@ T.sprintf [T.Bold; T.white; T.on_red] "%s" 
            (String.sub file_line ~pos:col ~len);
          eprintf "%s%!" @@ T.sprintf style "%s" 
            (String.drop_prefix file_line (col + len));
          eprintf "%s%!" @@ T.sprintf [] "\n"
        | None -> ()
      );

      exit 1
