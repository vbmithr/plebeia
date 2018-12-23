(** Implementation of space-efficient binary Patricia trees in OCaml.
    The implementation is geared for used in Tezos, though it is rather
    generic. A stop-and-copy GC is provided. This implementation aims
    to maximize correctness and cares second about efficiency. Extracting
    and efficient C program from F* should be explored. *)

module Path : sig
  (** A module encapsulating the concept of a path through the Patricia tree.
      A path is a sequence of n full segments. The n-1 first segments end in
      a bud and the nth ends in a leaf. Internal segments are bit of paths
      encoded in the internal nodes of the Patricia tree while tip segments
      represent the bits of path encoded close to the leaf. *)

  type side = Left | Right
  (** Binary tree, by convention when a bool or a bit is used, 0 = false = Left
      and 1 = true = Right *)

  val dummy_side : side

  type segment = private side list
  (** A segment is always just a list of sides. TODO: use bit arithmetic for
      speed and memory footprint.*)

  type path = segment list
  (** A path is a list of full segments. *)

  val cut : segment -> (side * segment) option
  (** Cuts a path into a head and tail if not empty. *)

  val common_prefix : segment -> segment -> segment * segment * segment
  (** Factors a common prefix between two segments. *)

  val of_side_list : side list -> segment

end = struct
  type side = Left | Right
  let dummy_side = Left
  type segment = side list (* FIXME: use bit arithmetic *)
  type path = segment list
  let cut = function
    | [] -> None
    | h::t -> Some (h,t)

  let rec common_prefix seg1 seg2 = match (seg1, seg2) with
    | (h1 :: t1, h2 :: t2) ->
      if h1 = h2 then
        let (prefix, r1, r2) = common_prefix t1 t2 in
        (h1 :: prefix, r1, r2)
      else
        ([], seg1, seg2)
    | ([], _) -> ([], [], seg2)
    | (_, []) -> ([], seg1, [])

  let of_side_list l = l
end

module Value : sig
  (** Module encapsulating the values inserted in the Patricia tree. *)

  type t = private string
  (** Type of a value. *)

  type hash
  (** Type for the hash of a value. *)

  val hash : t -> hash
  (** Returns the hash of a value. *)

  val of_string : string -> t

  val to_string : t -> string

end = struct
  type t = string
  type hash = string
  let hash value = ignore value; failwith "not implemented"
  let of_string s = s
  let to_string s = s
end


module KeyValueStore : sig
  (** Key-value store for leaf data using reference counting
      for deletion. TODO provide persistence to disk. *)

  (** Type of a key-value store. *)
  type t

  (** New, empty table *)
  val make : unit -> t

  (** Inserts a key in the table, or update the reference
      count if the key is already present. *)
  val insert   : t -> Value.t -> Value.hash

  (** Gets a value from the table, returns None if the key
      is not present. *)
  val get_opt  : t -> Value.hash -> Value.t option

  (** Decrements the reference counter of a key in the table.
      Deletes the key if the counter falls to 0. *)
  val decr     : t -> Value.hash -> unit

end = struct
  type t = (Value.hash, (Value.t * int)) Hashtbl.t
  let make () = Hashtbl.create 0

  let insert table value =
    let h = Value.hash value in
    match Hashtbl.find_opt table h with
    | None -> Hashtbl.add table h (value, 1) ; h
    | Some (_, count) -> Hashtbl.replace table h (value, count+1) ; h
  let get_opt table h =
    match Hashtbl.find_opt table h with
    | None -> None
    | Some (v, _) -> Some v
  let decr table h =
    match Hashtbl.find_opt table h with
    | None -> Printf.printf "none\n" ; ()
    | Some (_, 1) -> Printf.printf "some 1\n" ; Hashtbl.remove table h
    | Some (v, count) -> Printf.printf "some %d\n" count ;
      Hashtbl.replace table h (v, count-1)
end

type indexed type not_indexed
type hashed type not_hashed

(* /!\ Beware, GADT festivities below. *)


type ('ia, 'ha) indexed_implies_hashed =
  | Indexed_and_Hashed : (indexed, hashed) indexed_implies_hashed
  | Not_Indexed_Any : (not_indexed, 'ha) indexed_implies_hashed
  (* Type used to prove that all indexed nodes have been hashed. *)

type ('ha, 'hb, 'hc) hashed_is_transitive =
  | Hashed : Bigstring.t -> (hashed, hashed, hashed) hashed_is_transitive
  | Not_Hashed : (not_hashed, 'hb, 'hc) hashed_is_transitive
  (* Type used to prove that if a node is hashed then so are its children.
     The type also provides the hash as a witness.*)

type ('ia, 'ib, 'ic) internal_node_indexing_rule =
  | All_Indexed : int64 -> (indexed, indexed, indexed) internal_node_indexing_rule
  | Left_Not_Indexed  : (not_indexed, not_indexed, 'ic) internal_node_indexing_rule
  | Right_Not_Indexed : (not_indexed, 'ib, not_indexed) internal_node_indexing_rule
  (* This rule expresses the following invariant : if a node is indexed, then
     its children are necessarily indexed. Less trivially, if a node is not
     indexed then at least one of its children is not yet indexed. The reason
     is that we never construct new nodes that just point to only existing
     nodes. This property guarantees that when we write internal nodes on
     disk, at least one of the child can be written adjacent to its parent. *)

type ('ia, 'ib) indexing_rule =
  | Indexed : int64 -> (indexed, indexed) indexing_rule
  | Not_Indexed : (not_indexed, 'ib) indexing_rule
  (* Type used to prove that if a node is indexed, then so are its
     children. Provides the index as a witness. *)

type ('ia, 'ha) node =
  | Null : (indexed, hashed) node
  (* Null nodes, used when the tree is small. As the tree becomes bigger,
     the leaf and bud segment of path is always large enough to accomodate the
     rest of the segment and Null nodes become vanishingly unlikely. *)

  | Disk : int64 -> (indexed, hashed) node
  (* Represents a node stored on the disk at a given index, the node hasn't
     been loaded yet. Although it's considered hash for simplicity's sake,
     reading the hash requires a disk access and is expensive. *)

  | View : ('a, 'ha) view -> ('ia, 'ha) node
  (* A view node is the in-memory structure manipulated by programs in order
     to compute edits to the context. New view nodes can be commited to disk
     once the computations are done. *)

and ('ia, 'ha) view =
  | Internal : ('ib, 'hb) node * ('ic, 'hc) node
               * ('ia, 'ib, 'ic) internal_node_indexing_rule
               * ('ha, 'hb, 'hc) hashed_is_transitive
               * ('ia, 'ha) indexed_implies_hashed
    -> ('ia, 'ha) view

  (* An internal node , left and right children and an internal path segment
     to represent part of the path followed by the key in the tree. *)

  | Extender : Path.segment * ('ib, 'hb) node
               * ('ia, 'ib) indexing_rule
               * ('ha, 'hb, 'hb) hashed_is_transitive
               * ('ia, 'ha) indexed_implies_hashed
    -> ('ia, 'ha) view

  | Bud : ('ib, 'hb) node
          * ('ia, 'ib) indexing_rule
          * ('ha, 'hb, 'hb) hashed_is_transitive
          * ('ia, 'ha) indexed_implies_hashed
    -> ('ia, 'ha) view
  (* Buds represent the end of a segment and the beginning of a new tree. They
     are used whenever there is a natural hierarchical separation in the key
     or, in general, when one wants to be able to grab sub-trees. For instance
     the big_map storage of a contract in Tezos would start from a bud. *)

  | Leaf: Value.t
          * ('ia, 'ia) indexing_rule
          * ('ha, 'ha, 'ha) hashed_is_transitive
          * ('ia, 'ha) indexed_implies_hashed
    -> ('ia, 'ha) view
  (* Leaf of a tree, the end of a path, contains or points to a value.
     The current implementation is a bit hackish and leaves are written
     on *two* cells, not one. This is important to keep in mind when
     committing the tree to disk.
  *)

type context =
  {
    array : Bigstring.t ;
    (* mmaped array where the nodes are written and indexed. *)

    mutable length : int64 ;
    (* Current length of the node table. *)

    leaf_table  : KeyValueStore.t ;
    (* Hash table  mapping leaf hashes to their values. *)

    roots_table : (Bigstring.t, int64) Hashtbl.t
    (* Hash table mapping root hashes to indices in the array. *)
  }

type ('i, 'h) tree =

  {
    context : context ;
    mutable root : (not_indexed, not_hashed) node
  }

let make_context ?pos ?(shared=false) ?(length=(-1)) fn =
  let fd = Unix.openfile fn [O_RDWR] 0o644 in
  let array =
    (* length = -1 means that the size of [fn] determines the size of
       [array]. *)
    let open Bigarray in
    array1_of_genarray @@ Unix.map_file fd ?pos
      char c_layout shared [| length |] in
  { array ;
    length = 0L ;
    leaf_table = KeyValueStore.make () ;
    roots_table = Hashtbl.create 1
  }

let empty = Null

let make_internal :
  (not_indexed, not_hashed) node ->
  ('ib, 'hb) node ->
  Path.side -> (not_indexed, not_hashed) node =
  fun fresh other fresh_side ->
    match fresh_side with
    | Left  -> View (
        Internal (fresh, other, Left_Not_Indexed, Not_Hashed, Not_Indexed_Any))
    | Right -> View (
        Internal (other, fresh, Right_Not_Indexed, Not_Hashed, Not_Indexed_Any))

let load_node context index = ignore (context, index) ; failwith "not implemented"

let rec string_of_tree : type i h . (i, h) node -> int -> string =
  fun root indent ->
    let indent_string = String.concat "" (List.init indent (fun _ -> " . ")) in
    match root with
    | Null -> Printf.sprintf "%s Null\n" indent_string
    | Disk index -> Printf.sprintf "%sDisk %Ld" indent_string index
    | View (Leaf (value, _, _, _)) ->
      Printf.sprintf "%sLeaf %s\n" indent_string (Value.to_string value)
    | View (Bud  (node , _, _, _)) ->
      Printf.sprintf "%sBud:\n%s" indent_string
        (string_of_tree node (indent + 1))
    | View (Internal (left, right, _, _, _)) ->
      Printf.sprintf "%sInternal:\n%s%s" indent_string
        (string_of_tree left (indent + 1))
        (string_of_tree right (indent + 1))
    | View (Extender (_, node, _, _, _)) ->
      Printf.sprintf "%sExtender:\n%s" indent_string
        (string_of_tree node (indent + 1))


let upsert : type i h .
  context ->
  (i, h) node ->
  Path.path ->
  Value.t ->
  ('ib, 'hb) node =

  fun context node path value ->

    let extend : Path.segment -> (not_indexed, not_hashed) node -> (not_indexed, not_hashed) node =
      fun segment node -> match Path.cut segment with
        | None   -> node
        | Some _ -> View (Extender (segment, node, Not_Indexed, Not_Hashed, Not_Indexed_Any)) in

    let leaf = View (Leaf (value, Not_Indexed, Not_Hashed, Not_Indexed_Any)) in

    let rec upsert_aux : type ia ha .
      (ia, ha) node ->
      Path.path ->
      Path.side -> ('ib, 'hb) node =
      fun node path side ->
        match (path, node) with

        | ([ ], _) -> failwith "Ran out of segments without terminating."
        (* No segment shouldn't happen. *)

        | (_, Disk index) ->
          upsert_aux (load_node context index) path side
        (* If we encounter a node still on the disk, load it and retry. *)

        | ([segment], Null) -> extend segment leaf

        | (segment :: remaining_path, Null) ->
          let bud = View (Bud (
              upsert_aux Null remaining_path Path.dummy_side,
              Not_Indexed, Not_Hashed, Not_Indexed_Any)) in
          extend segment bud

        | (segment :: remaining_path, View view_node) -> begin
            match view_node with

            | Internal (left, right, _, _, _) -> begin
                match Path.cut segment with
                | Some (Left, remaining_segment) ->
                  View (
                    Internal (
                      upsert_aux left (remaining_segment::remaining_path) Path.Left, right,
                      Left_Not_Indexed, Not_Hashed, Not_Indexed_Any))
                | Some (Right, remaining_segment) -> View (
                    Internal (
                      left, upsert_aux right (remaining_segment::remaining_path) Path.Right,
                      Right_Not_Indexed, Not_Hashed, Not_Indexed_Any))

                | None -> assert false (* a segment can't end on an internal node, by construction *)
              end

            | Leaf (other_value, _, _, _) ->
              ignore other_value;
              assert (remaining_path = []); (* FIXME, better handling of leaf / bud conflict *)
              leaf (* Upserting !!! *)

            | Bud (next_root, _, _, _) -> View (
                Bud (
                  upsert_aux next_root remaining_path Path.dummy_side,
                  Not_Indexed, Not_Hashed, Not_Indexed_Any))

            | Extender (extender_segment, node, _, _, _) ->
              let (common_segment, remaining_segment, remaining_extender) =
                Path.common_prefix segment extender_segment in begin

                (* here's what can happen
                   - common_prefix is empty : not a problem just create an internal node
                   and inject remaining_segment and remaining_extender right and left
                   (they must differ on the first bit if common_prefix is empty

                   - common_prefix is not empty : cut the extender to the common prefix,
                   take the remaining_extender and create a second extender in succession
                   then recursively insert with the remaining_segment at the new cross point

                   In general it would be useful to have an "extend" function which takes
                   a segment and a node and return just the node if the segment is empty
                   and an extender followed by the node otherwise
                *)


                match (Path.cut remaining_segment, Path.cut remaining_extender) with

                | (None, None) -> upsert_aux node remaining_path Path.dummy_side
                (* we traveled the length of the extender *)

                | (Some (Left, remaining_segment), Some (Right, remaining_extender)) -> begin
                    match Path.cut remaining_extender with
                    | None ->
                      extend common_segment (View (
                          Internal (
                            upsert_aux Null (remaining_segment::remaining_path) Path.Left,
                            node,
                            Left_Not_Indexed, Not_Hashed, Not_Indexed_Any)))
                    | Some _ ->
                      extend common_segment (View (
                          Internal (
                            upsert_aux Null (remaining_segment::remaining_path) Path.Left,
                            View (Extender (remaining_extender, node, Not_Indexed, Not_Hashed, Not_Indexed_Any)),
                            Left_Not_Indexed, Not_Hashed, Not_Indexed_Any)))
                  end

                | (Some (Right, remaining_segment), Some (Left, remaining_extender)) -> begin
                    match Path.cut remaining_extender with
                    | None ->
                      extend common_segment (View (
                          Internal (
                            node,
                            upsert_aux Null (remaining_segment::remaining_path) Path.Right,
                            Right_Not_Indexed, Not_Hashed, Not_Indexed_Any)))
                    | Some _ ->
                      extend common_segment (View (
                          Internal (
                            View (Extender (remaining_extender, node, Not_Indexed, Not_Hashed, Not_Indexed_Any)),
                            upsert_aux Null (remaining_segment::remaining_path) Path.Right,
                            Right_Not_Indexed, Not_Hashed, Not_Indexed_Any)))
                  end

                | _ -> assert false
              end
          end
    in
    upsert_aux node path Path.dummy_side



let context =
  let fn = Filename.temp_file "plebeia" "test" in
  make_context ~shared:true ~length:1024 fn

let root = empty
