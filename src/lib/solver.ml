module Git = Current_git

(* -------------------------- *)

let job_log job logs =
  let module X = Solver_api.Raw.Service.Log in
  X.local
  @@ object
       inherit X.service

       method write_impl params release_param_caps =
         let open X.Write in
         release_param_caps ();
         let msg = Params.msg_get params in
         logs := msg :: !logs;
         Current.Job.write job msg;
         Capnp_rpc_lwt.Service.(return (Response.create_empty ()))
     end

let perform_constrained_solve ~solver ~pool ~job ~(platform : Platform.t) ~opam constraints =
  let open Lwt.Syntax in
  let packages = List.map (fun (p, _, _) -> p) constraints in
  let request =
    {
      Solver_api.Worker.Solve_request.opam_repository_commit =
        opam |> Current_git.Commit.id |> Current_git.Commit_id.hash;
      pkgs = packages;
      constraints;
      platforms =
        [
          ( "base",
            Solver_api.Worker.Vars.
              {
                arch = platform.arch |> Platform.arch_to_string;
                os = "linux";
                os_family = Platform.os_family platform.system.os;
                os_distribution = "linux";
                os_version = Platform.os_version platform.system.os;
              } );
        ];
    }
  in
  let switch = Current.Switch.create ~label:"solver switch" () in
  Lwt.catch
    (fun () ->
      let* () = Current.Job.use_pool ~switch job pool in
      let logs = ref [] in
      let* res = 
        Capnp_rpc_lwt.Capability.with_ref (job_log job logs) @@ fun log ->
        Solver_api.Solver.solve solver request ~log 
      in
      let+ () = Current.Switch.turn_off switch in
      match res with
      | Ok [] -> Fmt.error_msg "no platform:\n%s" (String.concat "\n" (List.rev !logs))
      | Ok [ x ] ->
          let solution =
            List.map
              (fun (a, b) -> (OpamPackage.of_string a, List.map OpamPackage.of_string b))
              x.packages
          in
          Ok (solution, x.commit)
      | Ok _ -> Fmt.error_msg "??"
      | Error (`Msg msg) -> Fmt.error_msg "Error from solver: %s" msg)
    (fun exn ->
      let* () = Current.Switch.turn_off switch in
      raise exn)

let perform_solve ~solver ~pool ~job ~(platform : Platform.t) ~opam track =
  let open Lwt.Syntax in
  let package = Track.pkg track in
  let constraints =
    [ (OpamPackage.name_to_string package, `Eq, OpamPackage.version_to_string package) ]
  in
  let latest = Ocaml_version.Releases.latest |> Ocaml_version.to_string in
  let* res =
    perform_constrained_solve ~solver ~pool ~job ~platform ~opam
      (("ocaml-base-compiler", `Geq, "4.04.1") ::
       ("ocaml", `Leq, latest) :: constraints)
  in
  match res with
  | Ok x -> Lwt.return (Ok x)
  | Error (`Msg msg1) ->
      let+ res = perform_constrained_solve ~solver ~pool ~job ~platform ~opam
        (("ocaml-base-compiler", `Eq, "5.0.0~beta1") :: constraints)
      in
      Result.map_error (fun (`Msg msg) -> `Msg (msg1 ^ "\n" ^ msg)) res

let solver_version = "v2"

module Cache = struct

  let fname id track =
    let digest = Track.digest track in
    let name = Track.pkg track |> OpamPackage.name_to_string in
    let name_version = Track.pkg track |> OpamPackage.version_to_string in
    Fpath.(Current.state_dir id / name / name_version / digest)
  
  module V1 = struct
    (* Migration from the old cached results *)
    let id = "solver-cache-v1"

    type cache_value = Package.t option

    let fname = fname id

    let mem track =
      let fname = fname track in
      match Bos.OS.Path.exists fname with 
      | Ok true -> true 
      | _ -> false
    
    let remove track =
      let fname = fname track in
      Bos.OS.Path.delete fname |> Result.get_ok

    let read track : cache_value option =
      let fname = fname track in
      try
        let file = open_in (Fpath.to_string fname) in
        let result = Marshal.from_channel file in
        close_in file;
        Some result
      with Failure _ -> None
  end

  let id = "solver-cache-" ^ solver_version

  type cache_value = (Package.t, string) result

  let fname = fname id

  let mem track =
    let fname = fname track in
    match Bos.OS.Path.exists fname with 
    | Ok true -> true 
    | _ -> V1.mem track

  let write ((track, value) : Track.t * cache_value) =
    let fname = fname track in
    let _ = Bos.OS.Dir.create (fst (Fpath.split_base fname)) |> Result.get_ok in
    let file = open_out (Fpath.to_string fname) in
    Marshal.to_channel file value [];
    close_out file

  let read track : cache_value option =
    let fname = fname track in
    try
      let file = open_in (Fpath.to_string fname) in
      let result = Marshal.from_channel file in
      close_in file;
      Some result
    with Failure _ | Sys_error _ ->
    match V1.read track with
    | None -> None
    | Some v ->
      let result = 
        Option.to_result ~none:"v1 solver did not record failure logs" v
      in
      write (track, result);
      V1.remove track;
      Some result

end

type key = Track.t
type t = {
  successes: Track.t list;
  failures: Track.t list;
}

let keys t = t.successes
let get key = Cache.read key |> Option.get (* is in cache ? *) |> Result.get_ok
let failures t =
  t.failures |> 
  List.map (fun k -> 
    Track.pkg k,
    Cache.read k |> Option.get |> Result.get_error)

(* is solved ? *)

(* ------------------------- *)
module Solver = struct
  type outcome = t

  type t = Solver_api.Solver.t * unit Current.Pool.t

  let id = "incremental-solver-" ^ solver_version
  let pp f _ = Fmt.pf f "incremental solver %s" solver_version
  let auto_cancel = false
  let latched = true

  (* A single instance of the solver is expected. *)
  module Key = Current.Unit

  module Value = struct
    type t = {
      packages : Track.t list;
      blacklist : string list;
      platform : Platform.t;
      opam_commit : Git.Commit.t;
    }

    (* TODO: what happens when the platform changes. *)
    let digest { packages; blacklist; opam_commit; _ } =
      (Git.Commit.hash opam_commit :: blacklist)
      @ List.map (fun t -> (Track.pkg t |> OpamPackage.to_string) ^ "-" ^ Track.digest t) packages
      |> Digestif.SHA256.digestv_string |> Digestif.SHA256.to_hex
  end

  module Outcome = struct
    type nonrec t = outcome

    let marshal t = Marshal.to_string t []
    let unmarshal t = Marshal.from_string t 0
  end

  let run (solver, pool) job () Value.{ packages; blacklist; platform; opam_commit } =
    let open Lwt.Syntax in
    let* () = Current.Job.start ~level:Harmless job in
    let to_do = List.filter (fun x -> not (Cache.mem x)) packages in
    let* solved =
      Lwt_list.map_p
        (fun pkg ->
          let+ res = perform_solve ~solver ~pool ~job ~opam:opam_commit ~platform pkg in
          let root = Track.pkg pkg in
          let result =
            match res with
            | Ok (packages, commit) -> Ok (Package.make ~blacklist ~commit ~root packages)
            | Error (`Msg msg) ->
                Current.Job.log job "Solving failed for %s: %s" (OpamPackage.to_string root) msg;
                Error msg
          in
          Cache.write (pkg, result);
          Result.is_ok result)
        to_do
    in
    Current.Job.log job "Solved: %d / New: %d / Success: %d" (List.length packages)
      (List.length solved)
      (List.length (solved |> List.filter (fun x -> x)));

    let successes, failures = 
      List.partition (fun x -> 
        match Cache.read x with
        | Some (Ok _) -> true
        | _ -> false)
      packages
    in
    Lwt.return_ok 
      {
        successes;
        failures
      }
end

module SolverCache = Current_cache.Generic (Solver)

let solver_pool = ref None

let solver_pool config =
  match !solver_pool with
  | None ->
      let jobs = Config.jobs config in
      let s = Solver_pool.spawn_local ~jobs () in
      let pool = Current.Pool.create ~label:"solver" jobs in
      solver_pool := Some (s, pool);
      (s, pool)
  | Some s -> s

let incremental ~config ~(blacklist : string list) ~(opam : Git.Commit.t Current.t)
    (packages : Track.t list Current.t) : t Current.t =
  let open Current.Syntax in
  let solver_pool = solver_pool config in
  Current.component "incremental solver"
  |> let> opam = opam and> packages = packages in
     SolverCache.run solver_pool ()
       { packages; blacklist; platform = Platform.platform_amd64; opam_commit = opam }
