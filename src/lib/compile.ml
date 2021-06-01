type t = { package : Package.t; blessed : bool; odoc : Mld.Gen.odoc_dyn; artifacts_digest : string }

let digest t =
  Package.digest t.package ^ Bool.to_string t.blessed ^ Mld.Gen.digest t.odoc ^ t.artifacts_digest

let artifacts_digest t = t.artifacts_digest

let is_blessed t = t.blessed

let odoc t = t.odoc

let package t = t.package

let network = Misc.network

let compile_folder ~blessed package =
  let universe = Package.universe package |> Package.Universe.hash in
  let opam = Package.opam package in
  let name = OpamPackage.name_to_string opam in
  let version = OpamPackage.version_to_string opam in
  if blessed then Fpath.(v "compile" / "packages" / name / version)
  else Fpath.(v "compile" / "universes" / universe / name / version)

let linked_folder ~blessed package =
  let universe = Package.universe package |> Package.Universe.hash in
  let opam = Package.opam package in
  let name = OpamPackage.name_to_string opam in
  let version = OpamPackage.version_to_string opam in
  if blessed then Fpath.(v "linked" / "packages" / name / version)
  else Fpath.(v "linked" / "universes" / universe / name / version)

let import_deps t =
  let compile_folders =
    List.map (fun { package; blessed; _ } -> compile_folder ~blessed package) t
  in
  let linked_folders = List.map (fun { package; blessed; _ } -> linked_folder ~blessed package) t in
  Misc.rsync_pull (linked_folders @ compile_folders)

let spec ~ssh ~branch ~remote_cache ~cache_key ~artifacts_digest ~base ~voodoo ~deps ~blessed prep =
  let open Obuilder_spec in
  let prep_folder = Prep.folder prep in
  let package = Prep.package prep in
  let compile_folder = compile_folder ~blessed package in
  let linked_folder = linked_folder ~blessed package in
  let opam = package |> Package.opam in
  let name = opam |> OpamPackage.name_to_string in
  let tools = Voodoo.Do.spec ~base voodoo |> Spec.finish in
  base |> Spec.children ~name:"tools" tools
  |> Spec.add
       [
         workdir "/home/opam/docs/";
         run "sudo chown opam:opam . ";
         (* obtain the compiled dependencies *)
         Spec.add_rsync_retry_script;
         import_deps ~ssh deps;
         (* obtain the prep folder *)
         Misc.rsync_pull ~ssh ~digest:(Prep.artifacts_digest prep) [ prep_folder ];
         run "find . -type d";
         (* prepare the compilation folder *)
         run "%s"
         @@ Fmt.str "mkdir -p %a && mkdir -p %a" Fpath.pp compile_folder Fpath.pp linked_folder;
         (* remove eventual leftovers (should not be needed)*)
         run
           "rm -f compile/packages.mld compile/page-packages.odoc compile/packages/*.mld \
            compile/packages/*.odoc";
         run "rm -f compile/packages/%s/*.odoc" name;
         (* Import odoc and voodoo-do *)
         copy ~from:(`Build "tools")
           [ "/home/opam/odoc"; "/home/opam/voodoo-do"; "/home/opam/voodoo-gen" ]
           ~dst:"/home/opam/";
         run "mv ~/odoc $(opam config var bin)/odoc";
         run "cp ~/voodoo-gen $(opam config var bin)/voodoo-gen";
         (* Run voodoo-do *)
         run "OCAMLRUNPARAM=b opam exec -- /home/opam/voodoo-do -p %s %s" name
           (if blessed then "-b" else "");
         run "mkdir -p html";
         (* Cache invalidation *)
         run "echo '%s'" (artifacts_digest ^ cache_key);
         (* Extract compile and linked folders *)
         run ~secrets:Config.Ssh.secrets ~network
           "rsync -avzR /home/opam/docs/./compile/ /home/opam/docs/./linked/ %s:%s/"
           (Config.Ssh.host ssh) (Config.Ssh.storage_folder ssh);
         (* Extract html/tailwind output *)
         Git_store.Cluster.clone ~branch ~directory:"git-store" ssh;
         run "rm -rf git-store/html && mv html/tailwind git-store/html";
         workdir "git-store";
         run "git add --all";
         run "git commit -m 'docs ci update %s\n\n%s' --allow-empty"
           (Fmt.to_to_string Package.pp package)
           cache_key;
         Git_store.Cluster.push ssh;
         workdir "..";
         (* extract html output*)
         run ~secrets:Config.Ssh.secrets ~network "rsync -avzR /home/opam/docs/./html/ %s:%s/"
           (Config.Ssh.host ssh) (Config.Ssh.storage_folder ssh);
       ]

let git_update_pool = Current.Pool.create ~label:"git merge into live" 1

module Compile = struct
  type output = t

  type t = No_context

  let id = "voodoo-do"

  module Value = Current.String

  module Key = struct
    type t = {
      config : Config.t;
      deps : output list;
      prep : Prep.t;
      blessed : bool;
      voodoo : Voodoo.Do.t;
    }

    let key { config; deps; prep; blessed; voodoo } =
      Fmt.str "v2-%s-%s-%s-%a-%s-%s" (Bool.to_string blessed)
        (Prep.package prep |> Package.digest)
        (Prep.artifacts_digest prep)
        Fmt.(list (fun f { artifacts_digest; _ } -> Fmt.pf f "%s" artifacts_digest))
        deps (Voodoo.Do.digest voodoo) (Config.odoc config)

    let digest t = key t |> Digest.string |> Digest.to_hex
  end

  let pp f Key.{ prep; _ } = Fmt.pf f "Voodoo do %a" Package.pp (Prep.package prep)

  let auto_cancel = true

  let remote_cache_key Key.{ voodoo; prep; deps; config; _ } =
    (* When this key changes, the remote artifacts will be invalidated. *)
    let deps_digest =
      Fmt.to_to_string
        Fmt.(list (fun f { artifacts_digest; _ } -> Fmt.pf f "%s" artifacts_digest))
        deps
      |> Digest.string |> Digest.to_hex
    in
    Fmt.str "voodoo-compile-v2-%s-%s-%s-%s" (Prep.artifacts_digest prep) deps_digest
      (Voodoo.Do.digest voodoo)
      (Config.odoc config |> Digest.string |> Digest.to_hex)

  let build digests job (Key.{ deps; prep; blessed; voodoo; config } as key) =
    let open Lwt.Syntax in
    let ( let** ) = Lwt_result.bind in
    let package = Prep.package prep in
    let folder = compile_folder ~blessed package in
    let cache_key = remote_cache_key key in
    Current.Job.log job "Cache digest: %s" (Key.key key);
    let base = Misc.get_base_image package in
    let branch = "html-" ^ (Prep.package prep |> Package.digest) in
    let spec =
      spec ~ssh:(Config.ssh config) ~branch ~remote_cache:digests ~cache_key ~artifacts_digest:""
        ~voodoo ~base ~deps ~blessed prep
    in
    let action = Misc.to_ocluster_submission spec in
    let version = Misc.base_image_version package in
    let cache_hint = "docs-universe-compile-" ^ version in
    let build_pool =
      Current_ocluster.Connection.pool ~job ~pool:(Config.pool config) ~action ~cache_hint
        ~secrets:(Config.Ssh.secrets_values (Config.ssh config))
        (Config.ocluster_connection_do config)
    in
    let* build_job = Current.Job.start_with ~pool:build_pool ~level:Mostly_harmless job in
    Current.Job.log job "Using cache hint %S" cache_hint;
    Capnp_rpc_lwt.Capability.with_ref build_job @@ fun build_job ->
    let* result = Current_ocluster.Connection.run_job ~job build_job in
    match result with
    | Error (`Msg _) as e -> Lwt.return e
    | Ok _ ->
        let ssh = Config.ssh config in
        let switch = Current.Switch.create ~label:"git merge pool switch" () in
        let* () = Current.Job.use_pool ~switch job git_update_pool in
        Lwt.catch
          (fun () ->
            let** () =
              (* this piece of magic invocations create a merge commit in the 'live' branch *)
              let live_ref = "refs/heads/live" in
              let update_ref = "refs/heads/" ^ branch in
              (* find nearest common ancestor of the two trees *)
              let git_merge_base = Fmt.str "git merge-base %s %s" live_ref update_ref in
              (* perform an aggressive merge *)
              let git_merge_trees =
                Fmt.str
                  "git read-tree --empty && git read-tree -mi --aggressive $(%s) %s %s && git \
                   merge-index ~/git-take-theirs.sh -a"
                  git_merge_base live_ref update_ref
              in
              (* create a commit object using the newly created tree *)
              let git_commit_tree =
                Fmt.str "git commit-tree $(git write-tree) -p %s -p %s -m 'update %a'" live_ref
                  update_ref Package.pp package
              in
              (* update the live branch *)
              let git_update_ref = Fmt.str "git update-ref %s $(%s)" live_ref git_commit_tree in

              Current.Process.exec ~cancellable:false ~job
                ( "",
                  [|
                    "ssh";
                    "-i";
                    Fpath.to_string (Config.Ssh.priv_key_file ssh);
                    "-p";
                    Config.Ssh.port ssh |> string_of_int;
                    Fmt.str "%s@%s" (Config.Ssh.user ssh) (Config.Ssh.host ssh);
                    Fmt.str "cd %s/git && %s && %s" (Config.Ssh.storage_folder ssh) git_merge_trees
                      git_update_ref;
                  |] )
            in
            let* () = Current.Switch.turn_off switch in
            failwith "todo")
          (fun exn ->
            let* () = Current.Switch.turn_off switch in
            raise exn)
end

module CompileCache = Current_cache.Make (Compile)

let v ~config ~name ~voodoo ~blessed ~deps prep =
  let open Current.Syntax in
  Current.component "do %s" name
  |> let> prep = prep
     and> voodoo = voodoo
     and> blessed = blessed
     and> deps = deps in
     let package = Prep.package prep in
     let opam = package |> Package.opam in
     let version = opam |> OpamPackage.version_to_string in
     let compile_folder = compile_folder ~blessed package in
     let odoc =
       Mld.
         {
           file = Fpath.(parent compile_folder / (version ^ ".mld"));
           target = None;
           name = version;
           kind = Mld;
         }
     in
     let digest = CompileCache.get No_context Compile.Key.{ prep; blessed; voodoo; deps; config } in
     Current.Primitive.map_result
       (Result.map (fun artifacts_digest -> { package; blessed; odoc = Mld odoc; artifacts_digest }))
       digest

let v ~config ~voodoo ~blessed ~deps prep =
  let open Current.Syntax in
  let* b_prep = prep in
  let name = b_prep |> Prep.package |> Package.opam |> OpamPackage.to_string in
  v ~config ~name ~voodoo ~blessed ~deps prep

let folder { package; blessed; _ } = compile_folder ~blessed package
