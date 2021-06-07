type t
(** The type for a prepped package (build objects in a universe/package folder) *)

val package : t -> Package.t

val v : config:Config.t -> voodoo:Voodoo.Prep.t Current.t -> Jobs.t -> t Package.Map.t Current.t
(** Install a package universe, extract useful files and push obtained universes. *)

val folder : t -> Fpath.t

val artifacts_digest : t -> string

val pp : t Fmt.t

val compare : t -> t -> int