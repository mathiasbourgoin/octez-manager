type network_info = {
  alias : string;
  network_url : string;
  human_name : string option;
  description : string option;
  faucet_url : string option;
  rpc_url : string option;
  docker_build : string option;
  git_ref : string option;
  last_updated : string option;
  category : string option;
}

val parse_networks : string -> (network_info list, [> Rresult.R.msg]) result

val list_networks :
  ?fetch:(unit -> (string, [> Rresult.R.msg]) result) ->
  unit ->
  (network_info list, [> Rresult.R.msg]) result

val fallback_pairs : (string * string) list
