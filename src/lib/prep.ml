let prep_version = "v3"
let network = Misc.network
let cache = Voodoo.cache

let not_base x =
  not
    (List.mem
       (OpamPackage.name_to_string x)
       [
         "base-unix";
         "base-bigarray";
         "base-threads";
         "ocaml-config";
         "ocaml";
         "ocaml-base-compiler";
         "ocaml-variants";
       ])

(* association list from package to universes encoded as "<PKG>:<UNIVERSE HASH>,..."
   to be consumed by voodoo-prep *)
let universes_assoc packages =
  packages
  |> List.map (fun pkg ->
         let hash = pkg |> Package.universe |> Package.Universe.hash in
         let name = pkg |> Package.opam |> OpamPackage.name_to_string in
         name ^ ":" ^ hash)
  |> String.concat ","

let spec ~ssh ~voodoo ~base ~(install : Package.t) (prep : Package.t list) =
  let open Obuilder_spec in
  (* the list of packages to install (which is a superset of the packages to prep) *)
  let all_deps = Package.all_deps install in
  let packages_str =
    all_deps
    |> List.map Package.opam
    |> List.filter not_base
    |> List.map OpamPackage.to_string
    |> String.concat " "
  in

  (* Only enable dune cache for dune >= 2.1 - to remove errors like:
     #=== ERROR while compiling base64.2.3.0 =======================================#
     # context              2.0.8 | linux/x86_64 | ocaml-base-compiler.4.06.1 | file:///src
     # path                 ~/.opam/4.06/.opam-switch/build/base64.2.3.0
     # command              ~/.opam/4.06/bin/dune build -p base64 -j 127
     # exit-code            1
     # env-file             ~/.opam/log/base64-1-9efc19.env
     # output-file          ~/.opam/log/base64-1-9efc19.out
     ### output ###
     # Error: link: /home/opam/.cache/dune/db/v2/temp/promoting: Invalid cross-device link
  *)
  let dune_cache_enabled =
    all_deps
    |> List.exists (fun p ->
           let opam = Package.opam p in
           let min_dune_version = OpamPackage.Version.of_string "2.1.0" in
           match OpamPackage.name_to_string opam with
           | "dune" ->
               OpamPackage.Version.compare (OpamPackage.version opam)
                 min_dune_version
               >= 0
           | _ -> false)
  in
  (* split install in two phases, the first installs the build system to favor cache sharing *)
  let build_preinstall =
    List.filter
      (fun pkg ->
        let name = pkg |> Package.opam |> OpamPackage.name_to_string in
        name = "dune" || name = "ocamlfind")
      all_deps
    |> function
    | [] -> comment "no build system"
    | lst ->
        let packages_str =
          lst
          |> List.sort Package.compare
          |> List.map (fun pkg -> Package.opam pkg |> OpamPackage.to_string)
          |> String.concat " "
        in
        run ~network ~cache "opam install %s" packages_str
  in

  let prep_storage_folders = List.rev_map (fun p -> (Storage.Prep, p)) prep in

  let create_dir_and_copy_logs_if_not_exist =
    let command =
      Fmt.str
        "([ -d $1 ] || (echo \"FAILED:$2\" && mkdir -p $1 && cp ~/opam.err.log \
         $1 && opam show $3 --raw > $1/opam)) && (%s)"
        (Misc.tar_cmd (Fpath.v "$1"))
    in
    Storage.for_all prep_storage_folders command
  in

  let tools = Voodoo.Prep.spec ~base voodoo |> Spec.finish in
  base
  |> Spec.children ~name:"tools" tools
  |> Spec.add
       [
         (* Install required packages *)
         run "sudo mkdir /src";
         copy [ "packages" ] ~dst:"/src/packages";
         copy [ "repo" ] ~dst:"/src/repo";
         (* Re-initialise opam after switching from opam.2.0 to 2.3. *)
         run ~network
           "sudo ln -f /usr/bin/opam-2.3 /usr/bin/opam && opam init --reinit \
            -ni";
         run "opam repo remove default && opam repo add opam /src";
         copy ~from:(`Build "tools")
           [ "/home/opam/voodoo-prep" ]
           ~dst:"/home/opam/";
         (* Pre-install build tools *)
         build_preinstall;
         (* Enable build cache conditionally on dune version *)
         env "DUNE_CACHE" (if dune_cache_enabled then "enabled" else "disabled");
         env "DUNE_CACHE_TRANSPORT" "direct";
         env "DUNE_CACHE_DUPLICATION" "copy";
         (* Intall packages. Recover in case of failure. *)
         run ~network ~cache "%s"
         @@ Misc.Cmd.list
              [
                "sudo apt update";
                Fmt.str
                  "(opam install -y %s 2>&1 | tee ~/opam.err.log) || echo \
                   'Failed to install all packages'"
                  packages_str;
              ];
         (* Perform the prep step for all packages *)
         run "opam exec -- ~/voodoo-prep -u %s" (universes_assoc prep);
         (* Extract artifacts  - cache needs to be invalidated if we want to be able to read the logs *)
         run ~network ~secrets:Config.Ssh.secrets "%s"
         @@ Misc.Cmd.list
              [
                Fmt.str "echo '%f'" (Random.float 1.);
                create_dir_and_copy_logs_if_not_exist;
                (* Extract *)
                Storage.for_all prep_storage_folders
                  (Fmt.str "rsync -aR --no-p ./$1 %s:%s/.;"
                     (Config.Ssh.host ssh)
                     (Config.Ssh.storage_folder ssh));
                (* Compute hashes *)
                Storage.for_all prep_storage_folders
                  (Storage.Tar.hash_command ~prefix:"HASHES" ());
              ];
       ]

module Prep = struct
  type t = No_context

  let id = "voodoo-prep"
  let auto_cancel = true

  module Key = struct
    type t = {
      job : Jobs.t;
      base : Spec.t;
      voodoo : Voodoo.Prep.t;
      config : Config.t;
    }

    let digest { job = { install; prep }; voodoo; base = _; config = _ } =
      (* base is derived from 'prep' so we don't need to include it in the hash *)
      Fmt.str "%s\n%s\n%s\n%s" prep_version (Package.digest install)
        (Voodoo.Prep.digest voodoo)
        (String.concat "\n"
           (List.rev_map Package.digest prep |> List.sort String.compare))
      |> Digest.string
      |> Digest.to_hex
  end

  let pp f Key.{ job = { install; _ }; _ } =
    Fmt.pf f "Voodoo prep %a" Package.pp install

  module Value = struct
    type item = Storage.id_hash [@@deriving yojson]
    type t = item list * string list [@@deriving yojson]

    let marshal t = t |> to_yojson |> Yojson.Safe.to_string
    let unmarshal t = t |> Yojson.Safe.from_string |> of_yojson |> Result.get_ok
  end

  let build No_context job Key.{ job = { install; prep }; base; voodoo; config }
      =
    let open Lwt.Syntax in
    let ( let** ) = Lwt_result.bind in
    (* Problem: no rebuild if the opam definition changes without affecting the universe hash.
       Should be fixed by adding the oldest opam-repository commit in the universe hash, but that
       requires changes in the solver.
       For now we rebuild only if voodoo-prep changes.
    *)
    let spec = spec ~ssh:(Config.ssh config) ~voodoo ~base ~install prep in
    let action = Misc.to_ocluster_submission spec in
    let commit_id =
      Current_git.Commit_id.v
        ~repo:"https://github.com/ocaml/opam-repository.git" ~gref:"master"
        ~hash:(Package.commit install)
    in
    let src =
      ( "https://github.com/ocaml/opam-repository.git",
        [ Package.commit install ] )
    in
    let version = Misc.cache_hint install in
    let cache_hint = "docs-universe-prep-" ^ version in
    let build_pool =
      Current_ocluster.Connection.pool ~job ~pool:(Config.pool config) ~action
        ~cache_hint ~src
        ~secrets:(Config.Ssh.secrets_values (Config.ssh config))
        (Config.ocluster_connection_prep config)
    in
    let* build_job =
      Current.Job.start_with ~pool:build_pool ~level:Mostly_harmless job
    in
    Current.Job.log job "Using cache hint %S" cache_hint;
    Current.Job.write job
      (Fmt.str
         "@.To reproduce locally:@.@.cat > prep.spec \
          <<'END-OF-SPEC'@.\o033[34m%s\o033[0m@.END-OF-SPEC@.@.ocluster-client \
          submit-obuilder %s %s --local-file prep.spec \\@.--pool linux-x86_64 \
          --connect ocluster-submission.cap --cache-hint %s \\@.--secret \
          ssh_privkey:id_rsa --secret ssh_pubkey:id_rsa.pub--secret \
          ssh_config:ssh_config@.@."
         (Spec.to_spec spec)
         (Current_git.Commit_id.repo commit_id)
         (Current_git.Commit_id.hash commit_id)
         cache_hint);

    Capnp_rpc_lwt.Capability.with_ref build_job @@ fun build_job ->
    (* extract result from logs *)
    let extract_hashes ((git_hashes, failed), retriable_errors) line =
      let retry_conditions log_line =
        let retry_on =
          [
            "Temporary failure";
            "Could not resolve host";
            "rsync: connection unexpectedly closed";
            "Disconnected: Switch turned off";
          ]
        in
        List.fold_left
          (fun acc str -> acc || Astring.String.is_infix ~affix:str log_line)
          false retry_on
      in
      let escape_on_success log_line =
        let escape_on = [ "Job succeeded" ] in
        List.fold_left
          (fun acc str -> acc || Astring.String.is_infix ~affix:str log_line)
          false escape_on
      in
      match Storage.parse_hash ~prefix:"HASHES" line with
      | Some value -> ((value :: git_hashes, failed), retriable_errors)
      | None -> (
          if escape_on_success line then ((git_hashes, failed), [])
            (* ignore retriable errors if the job has succeeded *)
          else if retry_conditions line then
            ((git_hashes, failed), line :: retriable_errors)
          else
            match String.split_on_char ':' line with
            | [ prev; branch ]
              when Astring.String.is_suffix ~affix:"FAILED" prev ->
                Current.Job.log job "Failed: %s" branch;
                ((git_hashes, branch :: failed), retriable_errors)
            | _ -> ((git_hashes, failed), retriable_errors))
    in

    let fn () =
      let** _ = Current_ocluster.Connection.run_job ~job build_job in
      Misc.fold_logs build_job extract_hashes (([], []), [])
    in

    let** git_hashes, failed =
      Retry.retry_loop ~job ~log_string:(Current.Job.id job) fn
    in
    Lwt.return_ok
      ( List.map
          (fun (r : Storage.id_hash) ->
            Current.Job.log job "%s -> %s" r.id r.hash;
            r)
          git_hashes,
        failed )
end

module PrepCache = Current_cache.Make (Prep)

type prep_result = Success | Failed

type t = {
  base : Spec.t;
  hash : string;
  package : Package.t;
  result : prep_result;
}

let hash t = t.hash
let package t = t.package
let result t = t.result
let base t = t.base

type prep = t Package.Map.t

let pp f t = Fmt.pf f "%s:%s" (Package.id t.package) t.hash

let compare a b =
  match String.compare a.hash b.hash with
  | 0 -> Package.compare a.package b.package
  | v -> v

module StringMap = Map.Make (String)
module StringSet = Set.Make (String)

let combine ~base ~(job : Jobs.t) (artifacts_branches_output, failed_branches) =
  let packages = job.prep in
  let artifacts_branches_output =
    artifacts_branches_output
    |> List.to_seq
    |> Seq.map (fun Storage.{ id; hash } -> (id, hash))
    |> StringMap.of_seq
  in
  let failed_branches = StringSet.of_list failed_branches in
  packages
  |> List.to_seq
  |> Seq.filter_map (fun package ->
         let package_id = Package.id package in
         match StringMap.find_opt package_id artifacts_branches_output with
         | Some hash when StringSet.mem package_id failed_branches ->
             Some (package, { base; package; hash; result = Failed })
         | Some hash -> Some (package, { base; package; hash; result = Success })
         | None -> None)
  |> Package.Map.of_seq

let v ~config ~voodoo ~spec (job : Jobs.t) =
  let open Current.Syntax in
  Current.component "voodoo-prep %s" (job.install |> Package.digest)
  |> let> voodoo and> spec in
     PrepCache.get No_context { job; voodoo; config; base = spec }
     |> Current.Primitive.map_result (Result.map (combine ~base:spec ~job))

let extract ~(job : Jobs.t) (prep : prep Current.t) =
  let open Current.Syntax in
  List.map
    (fun package ->
      ( package,
        let+ prep in
        Package.Map.find package prep ))
    job.prep
  |> List.to_seq
  |> Package.Map.of_seq
