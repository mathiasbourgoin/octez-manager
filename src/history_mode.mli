type t = Rolling | Full | Archive

val default : t

val to_string : t -> string

val of_string : string -> (t, [> `Msg of string]) result

val pp : Format.formatter -> t -> unit
