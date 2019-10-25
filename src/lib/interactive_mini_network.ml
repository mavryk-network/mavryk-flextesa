open Internal_pervasives
open Console

let run state ~protocol ~size ~base_port ~clear_root ~no_daemons_for
    ?external_peer_ports ~nodes_history_mode_edits ~with_baking
    ?generate_kiln_config node_exec client_exec baker_exec endorser_exec
    accuser_exec test_kind () =
  ( if clear_root then
    Console.say state EF.(wf "Clearing root: `%s`" (Paths.root state))
    >>= fun () -> Helpers.clear_root state
  else Console.say state EF.(wf "Keeping root: `%s`" (Paths.root state)) )
  >>= fun () ->
  Helpers.System_dependencies.precheck state `Or_fail
    ~executables:
      [node_exec; client_exec; baker_exec; endorser_exec; accuser_exec]
  >>= fun () ->
  Console.say state EF.(wf "Starting up the network.")
  >>= fun () ->
  Test_scenario.network_with_protocol ?external_peer_ports ~protocol ~size
    ~nodes_history_mode_edits ~base_port state ~node_exec ~client_exec
  >>= fun (nodes, protocol) ->
  Console.say state EF.(wf "Network started, preparing scenario.")
  >>= fun () ->
  Tezos_client.rpc state
    ~client:(Tezos_client.of_node (List.hd_exn nodes) ~exec:client_exec)
    `Get ~path:"/chains/main/chain_id"
  >>= fun chain_id_json ->
  let network_id =
    match chain_id_json with `String s -> s | _ -> assert false in
  Asynchronous_result.map_option generate_kiln_config ~f:(fun kiln_config ->
      Kiln.Configuration_directory.generate state kiln_config
        ~peers:(List.map nodes ~f:(fun {Tezos_node.p2p_port; _} -> p2p_port))
        ~sandbox_json:(Tezos_protocol.sandbox_path state protocol)
        ~nodes:
          (List.map nodes ~f:(fun {Tezos_node.rpc_port; _} ->
               sprintf "http://localhost:%d" rpc_port))
        ~bakers:
          (List.map protocol.Tezos_protocol.bootstrap_accounts
             ~f:(fun (account, _) ->
               Tezos_protocol.Account.(name account, pubkey_hash account)))
        ~network_string:network_id ~node_exec ~client_exec
        ~protocol_execs:
          [(protocol.Tezos_protocol.hash, baker_exec, endorser_exec)])
  >>= fun (_ : unit option) ->
  let keys_and_daemons =
    let pick_a_node_and_client idx =
      match List.nth nodes ((1 + idx) mod List.length nodes) with
      | Some node -> (node, Tezos_client.of_node node ~exec:client_exec)
      | None -> assert false in
    Tezos_protocol.bootstrap_accounts protocol
    |> List.filter_mapi ~f:(fun idx acc ->
           let node, client = pick_a_node_and_client idx in
           let key = Tezos_protocol.Account.name acc in
           if List.mem ~equal:String.equal no_daemons_for key then None
           else
             Some
               ( acc
               , client
               , [ Tezos_daemon.baker_of_node ~exec:baker_exec ~client node ~key
                 ; Tezos_daemon.endorser_of_node ~exec:endorser_exec ~client
                     node ~key ] )) in
  ( if with_baking then
    let accusers =
      List.map nodes ~f:(fun node ->
          let client = Tezos_client.of_node node ~exec:client_exec in
          Tezos_daemon.accuser_of_node ~exec:accuser_exec ~client node) in
    List_sequential.iter accusers ~f:(fun acc ->
        Running_processes.start state (Tezos_daemon.process acc ~state)
        >>= fun {process= _; lwt= _} -> return ())
    >>= fun () ->
    List_sequential.iter keys_and_daemons ~f:(fun (acc, client, daemons) ->
        Tezos_client.wait_for_node_bootstrap state client
        >>= fun () ->
        let key, priv = Tezos_protocol.Account.(name acc, private_key acc) in
        Tezos_client.import_secret_key state client ~name:key ~key:priv
        >>= fun () ->
        say state
          EF.(
            desc_list
              (haf "Registration-as-delegate:")
              [ desc (af "Client:") (af "%S" client.Tezos_client.id)
              ; desc (af "Key:") (af "%S" key) ])
        >>= fun () ->
        Tezos_client.register_as_delegate state client ~key_name:key
        >>= fun () ->
        say state
          EF.(
            desc_list (haf "Starting daemons:")
              [ desc (af "Client:") (af "%S" client.Tezos_client.id)
              ; desc (af "Key:") (af "%S" key) ])
        >>= fun () ->
        List_sequential.iter daemons ~f:(fun daemon ->
            Running_processes.start state (Tezos_daemon.process daemon ~state)
            >>= fun {process= _; lwt= _} -> return ()))
  else
    List.fold ~init:(return []) keys_and_daemons
      ~f:(fun prev_m (acc, client, _) ->
        prev_m
        >>= fun prev ->
        Tezos_client.wait_for_node_bootstrap state client
        >>= fun () ->
        let key, priv = Tezos_protocol.Account.(name acc, private_key acc) in
        let keyed_client =
          Tezos_client.Keyed.make client ~key_name:key ~secret_key:priv in
        Tezos_client.Keyed.initialize state keyed_client
        >>= fun _ -> return (keyed_client :: prev))
    >>= fun clients ->
    Interactive_test.Pauser.add_commands state
      Interactive_test.Commands.[bake_command state ~clients] ;
    return () )
  >>= fun () ->
  let clients = List.map keys_and_daemons ~f:(fun (_, c, _) -> c) in
  Helpers.Shell_environement.(
    let path = Paths.root state // "shell.env" in
    let env = build state ~clients in
    write state env ~path >>= fun () -> return (help_command state env ~path))
  >>= fun shell_env_help ->
  match test_kind with
  | `Interactive ->
      Interactive_test.Pauser.add_commands state
        Interactive_test.Commands.(
          (shell_env_help :: all_defaults state ~nodes)
          @ [secret_keys state ~protocol]
          @ arbitrary_commands_for_each_and_all_clients state ~clients) ;
      Interactive_test.Pauser.generic ~force:true state
        EF.[haf "Sandbox is READY \\o/"]
  | `Wait_level (`At_least lvl as opt) ->
      let seconds =
        let tbb =
          protocol.Tezos_protocol.time_between_blocks |> List.hd
          |> Option.value ~default:10 in
        float tbb *. 3. in
      let attempts = lvl in
      Test_scenario.Queries.wait_for_all_levels_to_be state ~attempts ~seconds
        nodes opt

let cmd ~pp_error () =
  let open Cmdliner in
  let open Term in
  Test_command_line.Run_command.make ~pp_error
    ( pure
        (fun test_kind
             (`Clear_root clear_root)
             size
             base_port
             (`External_peers external_peer_ports)
             (`No_daemons_for no_daemons_for)
             (`With_baking with_baking)
             protocol
             bnod
             bcli
             bak
             endo
             accu
             generate_kiln_config
             nodes_history_mode_edits
             state
             ->
          let actual_test =
            run state ~size ~base_port ~protocol bnod bcli bak endo accu
              ~clear_root ~nodes_history_mode_edits ~with_baking
              ?generate_kiln_config ~external_peer_ports ~no_daemons_for
              test_kind in
          (state, Interactive_test.Pauser.run_test ~pp_error state actual_test))
    $ Arg.(
        pure (fun level_opt ->
            match level_opt with
            | Some l -> `Wait_level (`At_least l)
            | None -> `Interactive)
        $ value
            (opt (some int) None
               (info ["until-level"]
                  ~doc:"Run the sandbox until a given level (not interactive)")))
    $ Arg.(
        pure (fun kr -> `Clear_root (not kr))
        $ value
            (flag
               (info ["keep-root"]
                  ~doc:"Do not erase the root path before starting.")))
    $ Arg.(
        value & opt int 5
        & info ["size"; "S"] ~doc:"Set the size of the network.")
    $ Arg.(
        value & opt int 20_000
        & info ["base-port"; "P"] ~doc:"Base port number to build upon.")
    $ Arg.(
        pure (fun l -> `External_peers l)
        $ value
            (opt_all int []
               (info ["add-external-peer-port"] ~docv:"PORT-NUMBER"
                  ~doc:"Add $(docv) to the peers of the network nodes.")))
    $ Arg.(
        pure (fun l -> `No_daemons_for l)
        $ value
            (opt_all string []
               (info ["no-daemons-for"] ~docv:"ACCOUNT-NAME"
                  ~doc:"Do not start daemons for $(docv).")))
    $ Arg.(
        pure (fun x -> `With_baking (not x))
        $ value
            (flag
               (info ["no-baking"]
                  ~doc:
                    "Completely disable baking/endorsing/accusing (you need \
                     to bake manually to make the chain advance).")))
    $ Tezos_protocol.cli_term ()
    $ Tezos_executable.cli_term `Node "tezos"
    $ Tezos_executable.cli_term `Client "tezos"
    $ Tezos_executable.cli_term `Baker "tezos"
    $ Tezos_executable.cli_term `Endorser "tezos"
    $ Tezos_executable.cli_term `Accuser "tezos"
    $ Kiln.Configuration_directory.cli_term ()
    $ Tezos_node.History_modes.cmdliner_term ()
    $ Test_command_line.cli_state ~name:"mininet" () )
    (let doc = "Small network sandbox with bakers, endorsers, and accusers." in
     let man : Manpage.block list =
       [ `P
           "This test builds a small sandbox network, start various daemons, \
            and then gives the user an interactive command prompt to inspect \
            the network." ] in
     info "mini-network" ~man ~doc)
