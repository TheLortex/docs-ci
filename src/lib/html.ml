type hashes = { html_tailwind_hash : string; html_classic_hash : string } [@@deriving yojson]

type t = { package : Package.t; blessing : Package.Blessing.t; hashes : hashes }

let hashes t = t.hashes

let blessing t = t.blessing

let package t = t.package

let spec ~ssh ~generation ~base ~voodoo ~blessed compiled =
  let open Obuilder_spec in
  let package = Compile.package compiled in
  let linked_folder = Storage.folder (Linked blessed) package in
  let tailwind_folder = Storage.folder (HtmlTailwind (generation, blessed)) package in
  let classic_folder = Storage.folder (HtmlClassic (generation, blessed)) package in
  let opam = package |> Package.opam in
  let name = opam |> OpamPackage.name_to_string in
  let version = opam |> OpamPackage.version_to_string in
  let tools = Voodoo.Gen.spec ~base voodoo |> Spec.finish in
  base |> Spec.children ~name:"tools" tools
  |> Spec.add
       [
         workdir "/home/opam/docs/";
         run "sudo chown opam:opam . ";
         (* obtain the linked folder *)
         run ~network:Misc.network ~secrets:Config.Ssh.secrets
           "rsync -aR %s:%s/./%s %s:%s/./%s/page-%s.odocl ." (Config.Ssh.host ssh)
           (Config.Ssh.storage_folder ssh) (Fpath.to_string linked_folder) (Config.Ssh.host ssh)
           (Config.Ssh.storage_folder ssh)
           Fpath.(to_string (parent linked_folder))
           (Package.opam package |> OpamPackage.version_to_string);
         run "find . -name '*.tar' -exec tar -xvf {} \\;";
         run "find . -type d -empty -delete";
         (* Import odoc and voodoo-do *)
         copy ~from:(`Build "tools")
           [ "/home/opam/odoc"; "/home/opam/voodoo-gen" ]
           ~dst:"/home/opam/";
         run "mv ~/odoc $(opam config var bin)/odoc";
         run "cp ~/voodoo-gen $(opam config var bin)/voodoo-gen";
         (* Run voodoo-gen *)
         run
           "OCAMLRUNPARAM=b opam exec -- /home/opam/voodoo-gen pkgver -o %s -n %s --pkg-version %s"
           (Fpath.to_string (Storage.Base.folder (HtmlTailwind generation)))
           name version;
         run
           "opam exec -- bash -c 'for i in $(find linked -name *.odocl); do odoc html-generate $i \
            -o %s; done'"
           (Fpath.to_string (Storage.Base.folder (HtmlClassic generation)));
         run "%s" @@ Fmt.str "mkdir -p %a %a" Fpath.pp tailwind_folder Fpath.pp classic_folder;
         (* Extract compile output   - cache needs to be invalidated if we want to be able to read the logs *)
         run "echo '%f'" (Random.float 1.);
         (* Extract tailwind and html output *)
         run ~network:Misc.network ~secrets:Config.Ssh.secrets "rsync -aR ./%s ./%s %s:%s/."
           (Fpath.to_string tailwind_folder) (Fpath.to_string classic_folder) (Config.Ssh.host ssh)
           (Config.Ssh.storage_folder ssh);
         (* Print hashes *)
         run "set '%s' tailwind; %s" (Fpath.to_string tailwind_folder)
           (Storage.hash_command ~prefix:"TAILWIND");
         run "set '%s' classic; %s" (Fpath.to_string classic_folder)
           (Storage.hash_command ~prefix:"CLASSIC");
       ]

let or_default a = function None -> a | b -> b

module Gen = struct
  type t = Epoch.t

  let id = "voodoo-gen"

  module Value = struct
    type t = hashes [@@deriving yojson]

    let marshal t = t |> to_yojson |> Yojson.Safe.to_string

    let unmarshal t = t |> Yojson.Safe.from_string |> of_yojson |> Result.get_ok
  end

  module Key = struct
    type t = { config : Config.t; compile : Compile.t; voodoo : Voodoo.Gen.t }

    let key { config; compile; voodoo } =
      Fmt.str "v6-%s-%s-%s-%s"
        (Compile.package compile |> Package.digest)
        (Compile.hashes compile).linked_hash (Voodoo.Gen.digest voodoo) (Config.odoc config)

    let digest t = key t |> Digest.string |> Digest.to_hex
  end

  let pp f Key.{ compile; _ } = Fmt.pf f "Voodoo gen %a" Package.pp (Compile.package compile)

  let auto_cancel = true

  let build generation job (Key.{ compile; voodoo; config } as key) =
    let open Lwt.Syntax in
    let ( let** ) = Lwt_result.bind in
    let blessed = Compile.blessing compile in
    Current.Job.log job "Cache digest: %s" (Key.key key);
    let spec =
      spec ~ssh:(Config.ssh config) ~generation ~voodoo ~base:Misc.default_base_image ~blessed
        compile
    in
    let action = Misc.to_ocluster_submission spec in
    let cache_hint = "docs-universe-gen" in
    let build_pool =
      Current_ocluster.Connection.pool ~job ~pool:(Config.pool config) ~action ~cache_hint
        ~secrets:(Config.Ssh.secrets_values (Config.ssh config))
        (Config.ocluster_connection_gen config)
    in
    let* build_job = Current.Job.start_with ~pool:build_pool ~level:Mostly_harmless job in
    Current.Job.log job "Using cache hint %S" cache_hint;
    Capnp_rpc_lwt.Capability.with_ref build_job @@ fun build_job ->
    let** _ = Current_ocluster.Connection.run_job ~job build_job in
    let extract_hashes (v_html_tailwind, v_html_classic) line =
      (* some early stopping could be done here *)
      let html_tailwind =
        Storage.parse_hash ~prefix:"TAILWIND" line |> or_default v_html_tailwind
      in
      let html_classic = Storage.parse_hash ~prefix:"CLASSIC" line |> or_default v_html_classic in
      (html_tailwind, html_classic)
    in
    let** html_tailwind, html_classic = Misc.fold_logs build_job extract_hashes (None, None) in
    try
      let html_tailwind = Option.get html_tailwind in
      let html_classic = Option.get html_classic in
      Lwt.return_ok
        { html_tailwind_hash = html_tailwind.hash; html_classic_hash = html_classic.hash }
    with Invalid_argument _ -> Lwt.return_error (`Msg "Gen: failed to parse output")
end

module GenCache = Current_cache.Make (Gen)

let v ~generation ~config ~name ~voodoo compile =
  let open Current.Syntax in
  Current.component "html %s" name
  |> let> compile = compile and> voodoo = voodoo and> generation = generation in
     let blessing = Compile.blessing compile in
     let package = Compile.package compile in
     let output = GenCache.get generation Gen.Key.{ compile; voodoo; config } in
     Current.Primitive.map_result (Result.map (fun hashes -> { package; blessing; hashes })) output
