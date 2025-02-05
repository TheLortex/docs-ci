module Worker = Solver_api.Worker
module Solver = Opam_0install.Solver.Make (Git_context)
module Store = Git_unix.Store
open Lwt.Infix

let env (vars : Worker.Vars.t) =
  let env =
    Opam_0install.Dir_context.std_env ~arch:vars.arch ~os:vars.os
      ~os_distribution:vars.os_distribution ~os_version:vars.os_version
      ~os_family:vars.os_family ()
  in
  function "opam-version" -> Some (OpamTypes.S "2.1.0") | v -> env v

let get_names = OpamFormula.fold_left (fun a (name, _) -> name :: a) []

let universes ~packages (resolutions : OpamPackage.t list) =
  let memo = Hashtbl.create (List.length resolutions) in

  let rec aux root =
    match Hashtbl.find_opt memo root with
    | Some universe -> universe
    | None ->
        let name, version = (OpamPackage.name root, OpamPackage.version root) in
        let opamfile : OpamFile.OPAM.t =
          packages
          |> OpamPackage.Name.Map.find name
          |> OpamPackage.Version.Map.find version
        in
        let deps =
          opamfile
          |> OpamFile.OPAM.depends
          |> OpamFilter.partial_filter_formula
               (OpamFilter.deps_var_env ~build:true ~post:false ~test:false
                  ~doc:false ~dev_setup:false ~dev:false)
          |> get_names
          |> OpamPackage.Name.Set.of_list
        in
        let depopts =
          opamfile
          |> OpamFile.OPAM.depopts
          |> OpamFilter.partial_filter_formula
               (OpamFilter.deps_var_env ~build:true ~post:false ~test:false
                  ~doc:false ~dev_setup:false ~dev:false)
          |> get_names
          |> OpamPackage.Name.Set.of_list
        in
        let deps =
          resolutions
          |> List.filter (fun res ->
                 let name = OpamPackage.name res in
                 OpamPackage.Name.Set.mem name deps
                 || OpamPackage.Name.Set.mem name depopts)
          |> List.rev_map (fun pkg -> OpamPackage.Set.add pkg (aux pkg))
        in
        let result =
          List.fold_left OpamPackage.Set.union OpamPackage.Set.empty deps
        in
        Hashtbl.add memo root result;
        result
  in
  List.rev_map
    (fun pkg -> (pkg, aux pkg |> OpamPackage.Set.elements))
    resolutions

let solve ~packages ~constraints ~root_pkgs (vars : Worker.Vars.t) =
  let context = Git_context.create () ~packages ~env:(env vars) ~constraints in
  let t0 = Unix.gettimeofday () in
  let r = Solver.solve context root_pkgs in
  let t1 = Unix.gettimeofday () in
  Printf.printf "%.2f\n" (t1 -. t0);
  match r with
  | Ok sels ->
      let pkgs = Solver.packages_of_result sels in
      let universes = universes ~packages pkgs in
      Ok
        (List.rev_map
           (fun (pkg, univ) ->
             (OpamPackage.to_string pkg, List.rev_map OpamPackage.to_string univ))
           universes)
  | Error diagnostics -> Error (Solver.diagnostics diagnostics)

type solve_result = (string * string list) list [@@deriving yojson]

let main commit =
  let packages =
    Lwt_main.run
      ( Opam_repository.open_store () >>= fun store ->
        Git_context.read_packages store commit )
  in
  let rec aux () =
    match input_line stdin with
    | exception End_of_file -> ()
    | len ->
        let len = int_of_string len in
        let data = really_input_string stdin len in
        let request =
          Worker.Solve_request.of_yojson (Yojson.Safe.from_string data)
          |> Result.get_ok
        in
        let {
          Worker.Solve_request.opam_repository_commit;
          pkgs;
          constraints;
          platforms;
        } =
          request
        in
        let opam_repository_commit = Store.Hash.of_hex opam_repository_commit in
        assert (Store.Hash.equal opam_repository_commit commit);
        let root_pkgs = pkgs |> List.rev_map OpamPackage.Name.of_string in
        let constraints =
          constraints
          |> List.rev_map (fun (name, rel, version) ->
                 ( OpamPackage.Name.of_string name,
                   (rel, OpamPackage.Version.of_string version) ))
          |> OpamPackage.Name.Map.of_list
        in
        platforms
        |> List.iter (fun (_id, platform) ->
               let msg =
                 match solve ~packages ~constraints ~root_pkgs platform with
                 | Ok packages ->
                     "+"
                     ^ (solve_result_to_yojson packages |> Yojson.Safe.to_string)
                 | Error msg -> "-" ^ msg
               in
               Printf.printf "%d\n%s%!" (String.length msg) msg);
        aux ()
  in
  aux ()

let main commit =
  try main commit
  with ex ->
    Fmt.epr "solver bug: %a@." Fmt.exn ex;
    let msg =
      match ex with Failure msg -> msg | ex -> Printexc.to_string ex
    in
    let msg = "!" ^ msg in
    Printf.printf "0.0\n%d\n%s%!" (String.length msg) msg;
    raise ex
