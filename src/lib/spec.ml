type t = {
  base : string;
  ops : Obuilder_spec.op list;
  children : (string * Obuilder_spec.t) list;
}

let add next_ops { base; ops; children } =
  { base; ops = ops @ next_ops; children }

let children ~name spec { base; ops; children } =
  { base; ops; children = (name, spec) :: children }

let finish { base; ops; children } =
  Obuilder_spec.stage ~child_builds:children ~from:base ops

(* https://gist.github.com/iangreenleaf/279849 *)
let rsync_retry_script =
  {|#!/bin/bash\n
MAX_RETRIES=10\n
i=0\n
false\n
while [ $? -ne 0 -a $i -lt $MAX_RETRIES ]\n
do\n
 i=$(($i+1))\n
 echo "Rsync ($i)"\n
 /usr/bin/rsync $@\n
done\n
if [ $i -eq $MAX_RETRIES ]\n
then\n
  echo "Hit maximum number of retries, giving up."\n
  exit 1\n
fi\n
|}

let add_rsync_retry_script =
  Obuilder_spec.run
    "printf '%s' | sudo tee -a /usr/local/bin/rsync && sudo chmod +x \
     /usr/local/bin/rsync && ls -l /usr/bin/rsync && cat /usr/local/bin/rsync"
    rsync_retry_script

let network = [ "host" ]

let make base =
  let open Obuilder_spec in
  {
    base;
    ops =
      [
        user_unix ~uid:1000 ~gid:1000;
        run ~network
          "sudo ln -f /usr/bin/opam-2.3 /usr/bin/opam && opam init --reinit -ni";
        workdir "/home/opam";
        run "sudo chown opam:opam /home/opam";
      ];
    children = [];
  }

let to_ocluster_spec build_spec =
  let spec_str = Fmt.to_to_string Obuilder_spec.pp (build_spec |> finish) in
  let open Cluster_api.Obuilder_job.Spec in
  { spec = `Contents spec_str }

let to_spec build_spec = Fmt.to_to_string Obuilder_spec.pp (build_spec |> finish)
