(*
 * Copyright (c) Citrix Systems Inc.
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
open Sexplib.Std
open Lwt
open Logging
open Clock

module Int64Map = struct
  include Map.Make(Int64)

  type 'a t' = (int64 * 'a) list with sexp
  let t_of_sexp a sexp =
    let t' = t'_of_sexp a sexp in
    List.fold_left (fun acc (x, y) -> add x y acc) empty t'
  let sexp_of_t a t = sexp_of_t' a (bindings t)
end

module Lwt_condition = struct
  include Lwt_condition
  type t' = string with sexp

  let t_of_sexp _ _ = Lwt_condition.create ()
  let sexp_of_t _ _ = sexp_of_t' "Lwt_condition.t"
end

module Lwt_mutex = struct
  include Lwt_mutex
  type t' = string with sexp

  let t_of_sexp _ = Lwt_mutex.create ()
  let sexp_of_t _ = sexp_of_t' "Lwt_mutex.t"
end

type waiter = {
  mutable next_id: int64;
  c: unit Lwt_condition.t;
  m: Lwt_mutex.t
} with sexp

type t = {
  q: Protocol.Entry.t Int64Map.t;
  name: string;
  length: int;
  owner: string option; (* if transient, name of the owning connection *)
  waiter: waiter;
} with sexp

let t_of_sexp sexp =
  let t = t_of_sexp sexp in
  (* compute a valid next_id *)
  let highest_id =
    try
      fst (Int64Map.max_binding t.q)
    with Not_found ->
      -1L in
  t.waiter.next_id <- Int64.succ highest_id;
  t

let get_owner t = t.owner

let make owner name =
  let waiter = {
    next_id = 0L;
    c = Lwt_condition.create ();
    m = Lwt_mutex.create ();
 } in {
  q = Int64Map.empty;
  name = name;
  length = 0;
  owner;
  waiter;
}

module StringMap = struct
  include Map.Make(String)

  type 'a t' = (string * 'a) list with sexp
  let t_of_sexp a sexp =
    let t' = t'_of_sexp a sexp in
    List.fold_left (fun acc (x, y) -> add x y acc) empty t'
  let sexp_of_t a t = sexp_of_t' a (bindings t)
end

module StringSet = struct
  include Set.Make(String)

  type t' = string list with sexp
  let t_of_sexp sexp =
    let t' = t'_of_sexp sexp in
    List.fold_left (fun acc x -> add x acc) empty t'
  let sexp_of_t t = sexp_of_t' (elements t)
end

type queues = {
  queues: t StringMap.t;
  by_owner: StringSet.t StringMap.t;
} with sexp

let empty = {
  queues = StringMap.empty;
  by_owner = StringMap.empty;
}

let owned_queues queues owner =
  if StringMap.mem owner queues.by_owner
  then StringMap.find owner queues.by_owner
  else StringSet.empty

let startswith prefix x = String.length x >= (String.length prefix) && (String.sub x 0 (String.length prefix) = prefix)

module Lengths = struct
  open Measurable
  let d x =Description.({ description = "length of queue " ^ x; units = "" })
  let list_available queues =
    StringMap.fold (fun name _ acc ->
        (name, d name) :: acc
      ) queues.queues []
  let measure queues name =
    if StringMap.mem name queues.queues
    then Some (Measurement.Int (StringMap.find name queues.queues).length)
    else None
end

(* operations which need to be persisted *)
module Op = struct
  type directory_operation =
    | Add of string option * string
    | Remove of string
  with sexp

  type t =
    | Directory of directory_operation
    | Ack of Protocol.message_id
    | Send of Protocol.origin * string * int64 * Protocol.Message.t (* origin * queue * id * body *)
  with sexp

  let of_cstruct x =
    try
      Some (Cstruct.to_string x |> Sexplib.Sexp.of_string |> t_of_sexp)
    with _ ->
      None

  let to_cstruct t =
    let s = sexp_of_t t |> Sexplib.Sexp.to_string in
    let c = Cstruct.create (String.length s) in
    Cstruct.blit_from_string s 0 c 0 (Cstruct.len c);
    c
end

module Redo_log = Shared_block.Journal.Make(Logging)(Block)(Time)(Clock)(Op)

module Internal = struct
module Directory = struct
  let waiters = Hashtbl.create 128

  let wait_for name =
    let t, u = Lwt.task () in
    let existing = if Hashtbl.mem waiters name then Hashtbl.find waiters name else [] in
    Hashtbl.replace waiters name (u :: existing);
    Lwt.on_cancel t
      (fun () ->
         if Hashtbl.mem waiters name then begin
           let existing = Hashtbl.find waiters name in
           Hashtbl.replace waiters name (List.filter (fun x -> x <> u) existing)
         end
      );
    t

  let exists queues name = StringMap.mem name queues.queues

  let add queues ?owner name =
    if not(exists queues name) then begin
      if Hashtbl.mem waiters name then begin
        let threads = Hashtbl.find waiters name in
        Hashtbl.remove waiters name;
        List.iter (fun u -> Lwt.wakeup_later u ()) threads
      end;
      let queues' = StringMap.add name (make owner name) queues.queues in
      let by_owner = match owner with
        | None -> queues.by_owner
        | Some owner ->
          let existing =
            if StringMap.mem owner queues.by_owner
            then StringMap.find owner queues.by_owner
            else StringSet.empty in
          StringMap.add owner (StringSet.add name existing) queues.by_owner in
      { queues = queues'; by_owner }
    end else queues

  let find queues name =
    if exists queues name
    then StringMap.find name queues.queues
    else make None name

  let remove queues name =
    let by_owner =
      if not(exists queues name)
      then queues.by_owner
      else
        let q = StringMap.find name queues.queues in
        match q.owner with
        | None -> queues.by_owner
        | Some owner ->
          let owned = StringMap.find owner queues.by_owner in
          let owned = StringSet.remove name owned in
          if owned = StringSet.empty
          then StringMap.remove owner queues.by_owner
          else StringMap.add owner owned queues.by_owner in
    let queues = StringMap.remove name queues.queues in
    { queues; by_owner }

  let list queues prefix = StringMap.fold (fun name _ acc ->
      if startswith prefix name
      then name :: acc
      else acc) queues.queues []
end

let transfer queues from names =
  let messages = List.map (fun name ->
      let q = Directory.find queues name in
      let _, _, not_seen = Int64Map.split from q.q in
      Int64Map.fold (fun id e acc ->
          ((name, id), e.Protocol.Entry.message) :: acc
        ) not_seen []
    ) names in
  List.concat messages

let queue_of_id = fst

let entry queues (name, id) =
  let q = Directory.find queues name in
  if Int64Map.mem id q.q
  then Some (Int64Map.find id q.q)
  else None

let ack queues (name, id) =
  if Directory.exists queues name then begin
    let q = Directory.find queues name in
    if Int64Map.mem id q.q then begin
      let q' = { q with
                 length = q.length - 1;
                 q = Int64Map.remove id q.q
               } in
      { queues with queues = StringMap.add name q' queues.queues }
    end else begin
      queues
    end
  end else begin
    queues
end

let wait_one queues from name =
  if Directory.exists queues name then begin
    (* Wait for some messages to turn up *)
    let q = Directory.find queues name in
    Lwt_mutex.with_lock q.waiter.m
      (fun () ->
        let rec loop () =
          (* q.next_id - 1 is the last id in use *)
          if from < (Int64.pred q.waiter.next_id)
          then return ()
          else begin
            Lwt_condition.wait ~mutex:q.waiter.m q.waiter.c
            >>= fun () ->
            loop ()
          end in
        loop ()
      )
  end else begin
    (* Wait for the queue to be created *)
    Directory.wait_for name;
  end

let wait queues from timeout names =
  let start = Clock.s () in 
  let remaining_timeout = max 0. (start +. timeout -. (Clock.s ())) in
  if remaining_timeout <= 0.
  then return ()
  else
    let timeout = Lwt_unix.sleep remaining_timeout in
    let more = List.map (wait_one queues from) names in
    Lwt.pick (timeout :: more)

let send queues origin name id data : queues Lwt.t =
  (* If a queue doesn't exist then drop the message *)
  if Directory.exists queues name then begin
    let q = Directory.find queues name in
    let q' = { q with
                length = q.length + 1;
                q = Int64Map.add id (Protocol.Entry.make (ns ()) origin data) q.q
              } in
     let queues = { queues with queues = StringMap.add name q' queues.queues } in
     Lwt_condition.broadcast q.waiter.c ();
     return queues
  end else return queues

let contents q = Int64Map.fold (fun i e acc -> ((q.name, i), e) :: acc) q.q []

let get_next_id queues name =
  let q = Directory.find queues name in
  let id = q.waiter.next_id in
  q.waiter.next_id <- Int64.succ id;
  return id
end

let perform_one queues = function
  | Op.Directory (Op.Add (owner, name)) ->
    return (Internal.Directory.add queues ?owner name)
  | Op.Directory (Op.Remove name) ->
    return (Internal.Directory.remove queues name)
  | Op.Ack id ->
    return (Internal.ack queues id)
  | Op.Send (origin, name, id, body) ->
    Internal.send queues origin name id body

let contents = Internal.contents

module Directory = struct
  let add queues ?owner name =
    let op = Op.Directory (Op.Add (owner, name)) in
    perform_one queues op
  let remove queues name =
    let op = Op.Directory (Op.Remove name) in
    perform_one queues op
  let find = Internal.Directory.find
  let list = Internal.Directory.list
end

let queue_of_id = Internal.queue_of_id
let ack queues id =
  let op = Op.Ack(id) in
  perform_one queues op
let transfer = Internal.transfer
let wait = Internal.wait
let entry = Internal.entry
let send queues origin name body =
  if Internal.Directory.exists queues name then begin
    let q = Directory.find queues name in
    Lwt_mutex.with_lock q.waiter.m
      (fun () ->
        Internal.get_next_id queues name
        >>= fun id ->
        let op = Op.Send(origin, name, id, body) in
        perform_one queues op
        >>= fun queues ->
        return (Some (queues, (name, id)))
      )
  end else return None (* drop *)
