(*
 * Copyright (c) 2021 Craig Ferguson <me@craigfe.io>
 *
 * Permission to use, copy, modify, and distribute this software for any
 * purpose with or without fee is hereby granted, provided that the above
 * copyright notice and this permission notice appear in all copies.
 *
 * THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
 * WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
 * ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 * WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
 * ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
 * OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 *)

let ( = ) : int -> int -> bool = ( = )
let ( <> ) : int -> int -> bool = ( <> )

let slot_taken = -1
let free_list_nil = -2

type entry_rec = { entry_data : unit; extra_data : unit; ptr : int }

(* [extra_data] is for keeping pointers passed to C alive. *)
type entry =
  | Empty
  | Entry of entry_rec

(* Free-list allocator *)
type t =
  { data: entry array
  (* Pool of potentially-empty data slots. Invariant: an unfreed pointer [p]
     into this array is valid iff [free_tail_relation.(p) = slot_taken]. *)
  ; mutable free_head: int
  ; free_tail_relation: int array
  (* A linked list of pointers to free slots, with [free_head] being the first
     element and [free_tail_relation] mapping each free slot to the next one.
     Each entry [x] signals a state of the corresponding [data.(x)] slot:

     - [x = slot_taken]: the data slot is taken;
     - [x = free_list_nil]: the data slot is free, and is last to be allocated;
     - [0 <= x < length data]: the data slot is free, and will be allocated before
       [free_tail_relation.(x)].

     The user is given only pointers [p] such that [free_tail_relation.(p) =
     slot_taken]. *)
  ; mutable in_use: int
  }

let get_ptr = function
  | Entry { ptr; _ } ->
    if ptr = -1 then invalid_arg "Entry has already been freed!"
    else ptr
  | Empty -> assert false
(*@ ptr x
      raises Invalid_argument _ -> True *)

let create n : t =
  if n < 0 || n > Sys.max_array_length then invalid_arg "Heap.create" ;
  (* Every slot is free, and all but the last have a free successor. *)
  let free_head = if n = 0 then free_list_nil else 0 in
  let free_tail_relation = Array.init n (fun i -> i + 1) in
  if n > 0 then free_tail_relation.(n - 1) <- free_list_nil;
  let data =
    (* No slot in [free_tail_relation] is [slot_taken], so initial data is
       inaccessible. *)
    Array.make n Empty
  in
  { data; free_head; free_tail_relation; in_use = 0 }
(*@ raises Invalid_argument *)

exception No_space

let alloc t entry_data ~extra_data =
  let ptr = t.free_head in
  if ptr = free_list_nil then raise No_space;
  let entry = Entry { entry_data; extra_data; ptr } in
  t.data.(ptr) <- entry;

  (* Drop [ptr] from the free list. *)
  let tail = t.free_tail_relation.(ptr) in
  t.free_tail_relation.(ptr) <- slot_taken;
  t.free_head <- tail;
  t.in_use <- t.in_use + 1;

  entry
(*@ raises No_space *)

let free t ptr =
  assert (ptr >= 0) (* [alloc] returns only valid pointers. *);
  if ptr >= Array.length t.data then invalid_arg "Heap.free: invalid pointer";
  let slot_state = t.free_tail_relation.(ptr) in
  if slot_state <> slot_taken then invalid_arg "Heap.free: pointer already freed";

  (* [t.free_tail_relation.(ptr) = slot_taken], so [t.data.(ptr)] is valid. *)
  let datum =
    match t.data.(ptr) with
    | Empty -> assert false
    | Entry p ->
      let p' = { p with ptr = -1 } in
      (* p.ptr <- -1; changed due to Why3 constraints*)
      t.data.(ptr) <- Entry p';
      p'.entry_data
  in

  (* Cons [ptr] to the free-list. *)
  t.free_tail_relation.(ptr) <- t.free_head;
  t.free_head <- ptr;

  (* We've marked this slot as free, so [t.data.(ptr)] is inaccessible. We zero
     it to allow it to be GC-ed. *)
  assert (t.free_tail_relation.(ptr) <> slot_taken);
  t.data.(ptr) <- Empty;         (* Extra-data can be GC'd here *)
  t.in_use <- t.in_use - 1;

  datum
(*@ raises Invalid_argument *)

let in_use_ t = t.in_use
