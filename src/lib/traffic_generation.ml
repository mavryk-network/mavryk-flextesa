open Internal_pervasives

module Michelson = struct
  let prepare_origination_of_id_script ?delegate ?(push_drops = 0)
      ?(amount = "2") state ~name ~from ~protocol_kind ~parameter ~init_storage
      =
    let id_script parameter =
      Fmt.strf
        "parameter %s;\n\
         storage %s;\n\
         code\n\
        \  {\n\
        \    %s\n\
        \    { CAR; NIL operation; PAIR }\n\
        \  };\n"
        parameter parameter
        ( match push_drops with
        | 0 -> "# No push-drops"
        | n ->
            Fmt.strf "# %d push-drop%s\n    %s" n
              (if n > 1 then "s" else "")
              ( List.init push_drops ~f:(fun ith ->
                    Fmt.strf "{ PUSH string %S ; DROP } ;"
                      (Fmt.strf
                         "push-dropping %d adds stupid bytes to the contract"
                         ith))
              |> String.concat ~sep:"\n    " ) ) in
    let tmp = Caml.Filename.temp_file "little-id-script" ".tz" in
    System.write_file state tmp ~content:(id_script parameter)
    >>= fun () ->
    Dbg.e EF.(wf "id_script %s: %s" parameter tmp) ;
    let origination =
      let opt = Option.value_map ~default:[] in
      ["--wait"; "none"; "originate"; "contract"; name]
      @ ( match protocol_kind with
        | `Athens -> ["for"; from]
        | `Carthage | `Babylon -> [] )
      @ [ "transferring"; amount; "from"; from; "running"; tmp; "--init"
        ; init_storage; "--force"; "--burn-cap"; "300000000000"
        ; (* ; "--fee-cap" ; "20000000000000" *) "--gas-limit"
        ; "1000000000000000"; "--storage-limit"; "20000000000000"
        ; "--verbose-signing" ]
      @ opt delegate ~f:(fun s -> (* Baby & Aths *) ["--delegate"; s]) in
    return origination
end

module Random = struct
  let run state ~protocol ~nodes ~clients ~until_level kind =
    assert (Poly.equal kind `Any) ;
    let tbb =
      protocol.Tezos_protocol.time_between_blocks |> List.hd
      |> Option.value ~default:10 in
    let info fmt =
      Fmt.kstr
        (fun s ->
          Console.sayf state Fmt.(fun ppf () -> pf ppf "Randomizer: %s" s))
        fmt in
    let from = "bootacc-0" in
    let client = List.hd_exn clients in
    let pp_success ppf = function
      | true -> Fmt.pf ppf "Success"
      | false -> Fmt.pf ppf "Failure" in
    let valid_contracts = ref [] in
    let rec loop iteration =
      let client_cmd name l =
        Tezos_client.client_cmd ~verbose:false state ~client
          ~id_prefix:(Fmt.str "randomizer-%04d-%s" iteration name)
          l in
      let continue_or_not () =
        Test_scenario.Queries.all_levels state ~nodes
        >>= fun all_levels ->
        if
          List.for_all all_levels ~f:(function
            | _, `Level l when l >= until_level -> true
            | _ -> false)
        then info "Max-level reached: %d" until_level
        else loop (iteration + 1) in
      List.random_element [`Sleep; `Add_contract; `Call_contract]
      |> function
      | Some `Sleep ->
          let secs =
            Float.(Random.float_range (of_int tbb * 0.3) (of_int tbb * 1.5))
          in
          info "Sleeping %.2f seconds." secs
          >>= fun () -> System.sleep secs >>= fun () -> continue_or_not ()
      | Some `Call_contract ->
          ( match List.random_element !valid_contracts with
          | None -> info "No valid contracts to call."
          | Some (name, params) ->
              client_cmd
                (Fmt.str "transfer-%s" name)
                ["transfer"; "1"; "from"; from; "to"; name; "--arg"; params]
              >>= fun (success, _) ->
              info "Called %s(%s): %a" name params pp_success success )
          >>= fun () -> continue_or_not ()
      | Some `Add_contract ->
          let name = Fmt.str "contract-%d" iteration in
          let push_drops = Random.int 100 in
          let parameter, init_storage =
            match List.random_element [`Unit; `String] with
            | Some `String ->
                ( "string"
                , Fmt.str "%S"
                    (String.init
                       (Random.int 42 + 1)
                       ~f:(fun _ -> Random.int 20 + 40 |> Char.of_int_exn)) )
            | _ -> ("unit", "Unit") in
          Michelson.prepare_origination_of_id_script state ~name ~from
            ~protocol_kind:protocol.Tezos_protocol.kind ~parameter
            ~init_storage ~push_drops
          >>= fun origination ->
          client_cmd (Fmt.str "originate-%s" name) origination
          >>= fun (success, _) ->
          if success then
            valid_contracts := (name, init_storage) :: !valid_contracts ;
          info "Origination of `%s` (%s : %s): `%a`." name init_storage
            parameter pp_success success
          >>= fun () -> continue_or_not ()
      | None -> continue_or_not () in
    loop 0
end
