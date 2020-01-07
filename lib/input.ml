type context = Utf8.context

type infos =
  { utf8         : context(** Uses utf8 for positions                 *)
  ; name         : string (** The name of the buffer (e.g. file name) *)
  ; uid          : int    (** Unique identifier                       *)
  ; rescan       : 'a. (int -> char -> 'a -> 'a) -> 'a -> int -> 'a
  ; lnum_skip    : (int * int) list
  }

type buffer =
  { boff         : int    (* Offset to the line ( bytes )            *)
  ; data         : string (* Contents of the buffer                  *)
  ; mutable next : buffer Lazy.t (* Following line                   *)
  ; mutable ctnr : Container.t option array
                          (* for map table, initialized if used      *)
  ; infos        : infos  (* infos common to the whole file          *)
  }

(* Generate a unique identifier. *)
let new_uid =
  let c = ref 0 in
  fun () -> let uid = !c in incr c; uid

(** infos function *)
let infos b = b.infos

let phantom_infos =
  { utf8 = Utf8.ASCII
  ; name = ""
  ; uid = new_uid ()
  ; rescan = (fun _ -> assert false)
  ; lnum_skip = [] }

(** idx type and constant *)
type idx = int

let init_idx = 0

(** byte_pos type and constant *)
type byte_pos = int

let int_of_byte_pos x = x

let init_byte_pos = 0

let phantom_byte_pos = -1

(** spos type  and constant *)
type spos = infos * byte_pos

let phantom_spos = (phantom_infos, phantom_byte_pos)

(* Emtpy buffer. *)
let empty_buffer infos boff =
  let rec line = lazy
    { boff; data = "" ; next = line ; infos ; ctnr = [||] }
  in Lazy.force line

let is_eof b = b.data = ""

let llen b = String.length b.data

(* Test if a buffer is empty. *)
let rec is_empty l idx =
  if idx < llen l then false
  else if idx = 0 then is_eof l
  else is_empty (Lazy.force l.next) (idx - llen l)

(* Read the character at the given position in the given buffer. *)
let [@inline] rec read l i =
  if i < llen l then (l.data.[i], l     , i+1)
  else if is_eof l then ('\255', l, 0)
  else read (Lazy.force l.next) (i - llen l)

(* Get the character at the given position in the given buffer. *)
let [@nline] rec get l i =
  if i < llen l then l.data.[i] else
  if is_eof l then '\255' else
  get (Lazy.force l.next) (i - llen l)

(* substring of a buffer *)
let sub b i len =
  let s = Bytes.create len in
  let rec fn b i j =
    if j = len then Bytes.unsafe_to_string s
    else
      let (c,b,i) = read b i in
      Bytes.set s j c;
      fn b i (j+1)
  in
  fn b i 0

(* Get the name of a buffer. *)
let filename infos = infos.name

(* byte position *)
let [@inline] byte_pos b p = b.boff + p

(* short position *)
let [@inline] spos b p = (b.infos, b.boff + p)

(* Get the current line number of a buffer, rescanning the file *)
let line_num infos i0 =
  let fn i c (l,ls) =
    match ls with
    | (j,l)::ls when i = j -> (l, ls)
    | _ -> if c = '\n' then (l+1, ls) else (l,ls)
  in
  let lnum_skip = List.rev infos.lnum_skip in
  fst (infos.rescan fn (1,lnum_skip) i0)

(* Get the current ascii column number of a buffer, rescanning *)
let ascii_col_num infos i0 =
  let fn _ c p = if c = '\n' then 0 else p+1 in
  infos.rescan fn 0 i0

exception Splitted_end
exception Splitted_begin

(** length of a utf8 string *)
let utf8_len context data =
  let len = String.length data in
  let rec find num pos =
    if pos < len then
      let cc = Char.code data.[pos] in
      let code i =
        if (pos+i) >= String.length data then raise Splitted_end;
        let n = match i with
          1 -> cc land 0b0111_1111
        | 2 -> (cc land (0b0001_1111) lsl 6) lor
                 (Char.code data.[pos+1] land 0b0011_1111)
        | 3 -> (cc land (0b0000_1111) lsl 12) lor
                 ((Char.code data.[pos+1] land 0b0011_1111) lsl 6)  lor
                   (Char.code data.[pos+2] land 0b0011_1111)
        | 4 -> (cc land (0b0000_0111) lsl 18) lor
                 ((Char.code data.[pos+1] land 0b0011_1111) lsl 12) lor
                   ((Char.code data.[pos+2] land 0b0011_1111) lsl 6)  lor
                     (Char.code data.[pos+3] land 0b0011_1111)
        | _ -> raise Splitted_begin
        in
        Uchar.of_int n
      in
      let (num, pos) =
        try
          if cc lsr 7 = 0 then
            (num+Utf8.width ~context (code 1), pos + 1)
          else if (cc lsr 5) land 1 = 0 then
            (num+Utf8.width ~context (code 2), pos + 2)
          else if (cc lsr 4) land 1 = 0 then
            (num+Utf8.width ~context (code 3), pos + 3)
          else if (cc lsr 3) land 1 = 0 then
            (num+Utf8.width ~context (code 4), pos + 4)
          else (num, pos+1) (* Invalid utf8 character. *)
        with Splitted_begin -> (num, pos+1)
           | Splitted_end   -> (num+1, String.length data)
      in
      find num pos
    else num
  in find 0 0

(* Get the utf8 column number corresponding to the given position. *)
let utf8_col_num infos i0 =
  let fn _ c cs = if c = '\n' then [] else c::cs in
  let cs = infos.rescan fn [] i0 in
  let len = List.length cs in
  let str = Bytes.create len in
  let rec fn cs p =
    match cs with
    | [] -> assert (p=0); ()
    | c::cs -> let p = p - 1 in
               Bytes.set str p c;
               fn cs p
  in
  fn cs len;
  utf8_len infos.utf8 (Bytes.unsafe_to_string str)

(* general column number *)
let col_num infos i0 =
  if infos.utf8 = ASCII then ascii_col_num infos i0 else utf8_col_num infos i0

(* Equality of buffers. *)
let buffer_equal b1 b2 =
  b1.infos.uid = b2.infos.uid && b1.boff = b2.boff

(* Comparison of buffers. *)
let buffer_compare b1 b2 =
  match b1.boff - b2.boff with
  | 0 -> b1.infos.uid - b2.infos.uid
  | c -> c

(* Get the unique identifier of the buffer. *)
let buffer_uid b = b.infos.uid

(* The way to rescan (using seek, keeping the buffer of no rescan *)
type 'a rescan_type =
  | Seek of ('a -> int) * ('a -> int -> unit)
  | Buf
  | NoRescan

module type MinimalInput =
  sig
    val from_fun : ('a -> unit) -> context -> string
                   -> ('a -> string)
                   -> 'a rescan_type -> 'a -> buffer
  end

let rescan_no _ _ _ =
  failwith "no line of column number available for this buffer"

let rescan_buf buf0 fn acc =
  let cache = ref [] in
  let set_cache i buf idx acc =
    cache := (i,buf, idx, acc) :: !cache
  in
  let get_cache i =
    let rec fn = function
        []                -> (Lazy.force buf0, 0, acc)
      | (j,buf,idx,acc)::ls -> if j <= i then (buf, idx, acc) else fn ls
    in
    fn !cache
  in
  fun i0 ->
    let (buf0,idx0,acc0) = get_cache i0 in
    let buf = ref buf0 in
    let acc = ref acc0 in
    let idx = ref idx0 in
    for i = 0 to i0 - 1 do
      if i mod 1024 = 0 then set_cache i !buf !idx !acc;
      let (c,b,p) = read !buf !idx in
      buf := b; idx := p;
      acc := fn i c !acc
    done;
    !acc

let rescan_seek ch pos_in seek_in mk_buf fn acc =
  let cache = ref [] in
  let set_cache i idx acc =
    cache := (i,pos_in ch, idx, acc) :: !cache
  in
  let get_cache i =
    let rec fn = function
        []                -> (0, 0, acc)
      | (j,p,idx,acc)::ls -> if j <= i then (p, idx, acc) else fn ls
    in
    fn !cache
  in
  fun i0 ->
    let saved = pos_in ch in
    let (p0,idx0,acc0) = get_cache i0 in
    seek_in ch p0;
    let buf = ref (mk_buf ()) in
    let acc = ref acc0 in
    let idx = ref idx0 in
    for i = 0 to i0 - 1 do
      if i mod 1024 = 0 then set_cache i !idx !acc;
      let (c,b,p) = read !buf !idx in
      buf := b; idx := p;
      acc := fn i c !acc
    done;
    seek_in ch saved;
    !acc

let buf_size = 0x10000

(* returns [(s,nl)] with [nl = true] iff there is a newline at the end of [s] *)
let input_buffer ch =
  let res = Bytes.create buf_size in
  let n = input ch res 0 buf_size in
  if n = 0 then (* n = 0: we are at EOF *)
    raise End_of_file
  else if n = buf_size then
    Bytes.unsafe_to_string res
  else
    Bytes.sub_string res 0 n

let fd_buffer fd =
  let res = Bytes.create buf_size in
  let n = Unix.read fd res 0 buf_size in
  if n = 0 then (* n = 0: we are at EOF *)
    raise End_of_file
  else if n = buf_size then
    Bytes.unsafe_to_string res
  else
    Bytes.sub_string res 0 n

module GenericInput(M : MinimalInput) =
  struct
    include M

    let st_fd rescan fd =
      let open Unix in
      let stat = fstat fd in
      let seek fd n = ignore (Unix.lseek fd n SEEK_SET) in
      let pos fd = Unix.lseek fd 0 SEEK_CUR in
      if rescan then
        if stat.st_kind = S_REG then Seek(pos,seek) else Buf
      else
        NoRescan

    let st_ch rescan ch =
      let open Unix in
      let stat = fstat (Unix.descr_of_in_channel ch) in
      if rescan then
        if stat.st_kind = S_REG then Seek(pos_in,seek_in) else Buf
      else
        NoRescan

    let from_channel
        : ?utf8:context -> ?filename:string -> ?rescan:bool
          -> in_channel -> buffer =
      fun ?(utf8=Utf8.ASCII) ?(filename="") ?(rescan=true) ch ->
        let st = st_ch rescan ch in
        from_fun ignore utf8 filename input_buffer st ch

    let from_fd
        : ?utf8:context -> ?filename:string -> ?rescan:bool
          -> Unix.file_descr -> buffer =
      fun ?(utf8=Utf8.ASCII) ?(filename="") ?(rescan=true) fd ->
        let st = st_fd rescan fd in
        from_fun ignore utf8 filename fd_buffer st fd

    let from_file : ?utf8:context -> ?rescan:bool -> string -> buffer =
      fun ?(utf8=Utf8.ASCII) ?(rescan=true) fname ->
        let fd = Unix.(openfile fname [O_RDONLY] 0) in
        let st = st_fd rescan fd in
        from_fun Unix.close utf8 fname fd_buffer st fd

    let from_string : ?utf8:context -> ?filename:string -> string -> buffer =
      fun ?(utf8=Utf8.ASCII) ?(filename="") str ->
      let b = ref true in
        let string_buffer =
          fun () -> if !b then (b := false; str) else raise End_of_file
        in
        let seek () n = b := (n <> (-1)) in
        let pos () = (-1) in
        let st = Seek(pos, seek) in
        from_fun ignore utf8 filename string_buffer st ()
  end

include GenericInput(
  struct
    let rec from_fun finalise utf8 name get_line st file =
      let rec rescan
              : type a.(byte_pos -> char -> a -> a) -> a -> byte_pos -> a =
        fun fn acc i0 ->
        match st with
        | Seek (pos, seek) ->
           rescan_seek file pos seek
             (fun () -> from_fun finalise utf8 name get_line st file)
             fn acc i0
        | Buf ->
           rescan_buf buf fn acc i0
        | NoRescan ->
           rescan_no fn acc i0
      and infos = { utf8; name; uid = new_uid (); rescan; lnum_skip = [] }
      and fn boff cont =
        begin
          (* Tail rec exception trick to avoid stack overflow. *)
          try
            let data = get_line file in
            let llen = String.length data in
            fun () ->
              { boff; data ; infos
              ; next = lazy (fn (boff + llen) cont)
              ; ctnr = [||] }
          with End_of_file ->
            finalise file;
            fun () -> cont boff
        end ()
      and buf = lazy
        begin
          let cont boff =
            empty_buffer infos boff
          in
          fn 0 cont
          end
      in
      Lazy.force buf
  end)

module type Preprocessor =
  sig
    type state
    val initial_state : state
    val update : state -> string -> string
                 -> state * (string option * int option * string) list
    val check_final : state -> string -> unit
  end

module Make(PP : Preprocessor) =
  struct
    let rec from_fun finalise utf8 name get_line st file =
      let rec rescan
              : type a.(byte_pos -> char -> a -> a) -> a -> byte_pos -> a =
        fun fn acc i0 ->
        match st with
        | Seek (pos, seek) ->
           rescan_seek file pos seek
             (fun () -> from_fun finalise utf8 name get_line st file)
             fn acc i0
        | Buf ->
           rescan_buf buf fn acc i0
        | NoRescan ->
           rescan_no fn acc i0
      and infos = { utf8; name; uid = new_uid (); rescan = rescan
                    ; lnum_skip = [] }
      and fn infos boff st cont =
        begin
          (* Tail rec exception trick to avoid stack overflow. *)
          try
            let data = get_line file in
            let (st, ls) = PP.update st infos.name data in
            let rec gn infos boff = function
              | [] -> fn infos boff st cont
              | (name, lnum, data) :: ls ->
                 let infos = match name with
                   | None      -> infos
                   | Some name -> { infos with name }
                 in
                 let infos = match lnum with
                   | None   -> infos
                   | Some l ->
                      { infos with lnum_skip = (boff, l) :: infos.lnum_skip }
                 in
                 if data = "" then gn infos boff ls
                 else
                   let llen = String.length data in
                   { boff; data ; infos
                     ; next = lazy (gn infos (boff + llen) ls)
                     ; ctnr = [||] }
            in
            fun () -> gn infos boff ls
          with End_of_file ->
            finalise file;
            fun () -> cont infos boff st
        end ()
      and buf = lazy
        begin
          let cont infos boff st =
            PP.check_final st infos.name;
            empty_buffer infos boff
          in
          fn infos 0 PP.initial_state cont
        end
      in
      Lazy.force buf
  end

module WithPP(PP : Preprocessor) = GenericInput(Make(PP))

let leq_buf {boff = b1} i1 {boff = b2} i2 =
  b1 < b2 || (b1 = b2 && (i1 <= i2))

let buffer_before b1 i1 b2 i2 = leq_buf b1 i1 b2 i2

(** Table to associate value to positions in input buffers *)
module Tbl = struct
  type 'a t = 'a Container.table

  let create = Container.create_table

  let ctnr buf idx =
    if buf.ctnr = [||] then
      buf.ctnr <- Array.make (llen buf + 1) None;
    let a = buf.ctnr.(idx) in
    match a with
    | None -> let c = Container.create () in buf.ctnr.(idx) <- Some c; c
    | Some c -> c

  let add tbl buf idx x =
    Container.add tbl (ctnr buf idx) x

  let find tbl buf idx =
    Container.find tbl (ctnr buf idx)

  let clear = Container.clear

  let iter : type a. a t -> (a -> unit) -> unit = fun tbl f ->
    Container.iter f tbl

end
