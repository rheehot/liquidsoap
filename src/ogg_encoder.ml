(*****************************************************************************

  Liquidsoap, a programmable audio stream generator.
  Copyright 2003-2008 Savonet team

  This program is free software; you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation; either version 2 of the License, or
  (at your option) any later version.

  This program is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
  GNU General Public License for more details, fully stated in the COPYING
  file at the root of the liquidsoap distribution.

  You should have received a copy of the GNU General Public License
  along with this program; if not, write to the Free Software
  Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA

 *****************************************************************************)

 (** Ogg Stream Encoder *)

let log = Dtools.Log.make ["ogg.encoder"]

exception Invalid_data
exception Invalid_usage

type audio = float array array
type video = RGB.t array array
type 'a data = 
  { 
    data   : 'a;
    offset : int;
    length : int
  }

type ogg_data = 
  | Audio_data of audio data
  | Video_data of video data

type ('a,'b) track_encoder = 'a -> 'b data -> Ogg.Stream.t -> unit
type header_encoder = Ogg.Stream.t -> Ogg.Page.t
type end_of_stream = Ogg.Stream.t -> unit

type ('a,'b) track = 
  {
    os             : Ogg.Stream.t;
    encoder        : ('a,'b) track_encoder;
    end_of_stream  : end_of_stream
  } 

type 'a ogg_track =
  | Audio_track of (('a,audio) track)
  | Video_track of (('a,video) track)

type t =
  {
    encoded : Buffer.t;
    tracks  : (nativeint,t ogg_track) Hashtbl.t;
    (** When end_of_stream as been
      * called on every stream,
      * flag is set to true.
      * You may, at this point, register
      * new tracks in order to start
      * a new sequentialized stream. *)
    bos     : bool ref;
    (** All multiplexed ogg streams
      * should be declared at once.
      * Once you submit track data,
      * this flag is set to false and you
      * will not be able to register new
      * tracks *)
    eos     : bool ref
  }

type ogg_data_encoder = 
  | Audio_encoder of ((t,audio) track_encoder)
  | Video_encoder of ((t,video) track_encoder)

type ogg_encoder = header_encoder*ogg_data_encoder*end_of_stream

let os_of_ogg_track x = 
  match x with
    | Audio_track x -> x.os
    | Video_track x -> x.os

let create () = 
  {
    encoded   = Buffer.create 1024;
    tracks = Hashtbl.create 10;
    eos    = ref false;
    bos    = ref true;
  }

let register_track encoder (header_enc,track_enc,end_of_stream) =
  if not !(encoder.bos) && not !(encoder.eos) then
   begin
    log#f 4 "Invalid new track: ogg stream already started..";
    raise Invalid_usage
   end;
  if !(encoder.eos) then
   begin
    log#f 4 "Starting new sequentialized ogg stream.";
    encoder.eos := false
   end;
  let rec gen_id () = 
    let id = Random.nativeint (Nativeint.of_int 0x3FFFFFFF) in 
    if Hashtbl.mem encoder.tracks id then
      gen_id ()
    else
      id
  in
  (** Initiate a new logical stream *)
  let id = gen_id () in
  let os = Ogg.Stream.create ~serial:id () in
  (** Encoder headers *) 
  let (h,v) = header_enc os in
  Buffer.add_string encoder.encoded (h^v);
  let track = 
    match track_enc with
      | Audio_encoder encoder -> 
         Audio_track 
           { 
             os = os; 
             encoder = encoder;
             end_of_stream = end_of_stream
           }
      | Video_encoder encoder -> 
         Video_track 
           { 
             os = os; 
             encoder = encoder;
             end_of_stream = end_of_stream
           }
  in
  Hashtbl.add encoder.tracks id track;
  id

let encode encoder id data =
 if !(encoder.bos) then
   encoder.bos := false;
 if !(encoder.eos) then
   begin
    log#f 4 "Cannot encode: ogg stream finished..";
    raise Invalid_usage
   end;
 let rec fill src dst = 
   try
     let (h,v) = Ogg.Stream.get_page src in
     Buffer.add_string dst (h^v);
     fill src dst
   with
     | Ogg.Not_enough_data -> ()
  in
  match data with
    | Audio_data x -> 
       begin
        match Hashtbl.find encoder.tracks id with
          | Audio_track t ->
             t.encoder encoder x t.os;
             fill t.os encoder.encoded
          | _ -> raise Invalid_data
       end
    | Video_data x -> 
       begin
        match Hashtbl.find encoder.tracks id with
          | Video_track t ->
             t.encoder encoder x t.os;
             fill t.os encoder.encoded
          | _ -> raise Invalid_data
       end

(** Get and remove encoded data.. *)
let get_data encoder = 
  let b = Buffer.contents encoder.encoded in
  Buffer.reset encoder.encoded;
  b

(** Peek encoded data without removing it. *)
let peek_data encoder =
  Buffer.contents encoder.encoded

(** Add an ogg page. *)
let add_page encoder (h,v) = 
  Buffer.add_string encoder.encoded h;
  Buffer.add_string encoder.encoded v

let flush encoder = 
  let flush_track _ x = 
    let os = os_of_ogg_track x in
    let b = Ogg.Stream.flush os in
    Buffer.add_string encoder.encoded b
  in
  Hashtbl.iter flush_track encoder.tracks;
  Hashtbl.clear encoder.tracks;
  let b = Buffer.contents encoder.encoded in
  Buffer.reset encoder.encoded;
  b

let end_of_track encoder id = 
  let track = Hashtbl.find encoder.tracks id in
  log#f 4 "Setting end of track %nx." id;
  begin
    match track with
        | Video_track x -> 
            x.end_of_stream x.os;
            Buffer.add_string encoder.encoded (Ogg.Stream.flush x.os)
        | Audio_track x -> 
            x.end_of_stream x.os;
            Buffer.add_string encoder.encoded (Ogg.Stream.flush x.os)
  end;
  Hashtbl.remove encoder.tracks id;
  if Hashtbl.length encoder.tracks = 0 then
   begin
    log#f 4 "Every ogg logical tracks have ended: setting end of stream.";
    encoder.eos := true
   end


let end_of_stream encoder = 
  Hashtbl.iter 
    (fun x -> fun _ -> end_of_track encoder x)
    encoder.tracks

