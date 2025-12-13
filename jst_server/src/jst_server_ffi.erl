%% Minimal Erlang FFI helpers for the Gleam backend.
-module(jst_server_ffi).

-export([
    getenv/1,
    ensure_all_started/1,
    recv_any/1,
    send_any/2,
    find_static_dir/0,
    json_decode/1,
    json_encode/1,
    base64url_encode/1,
    base64url_decode/1,
    hmac_sha512/2,
    sha512/1,
    nats_parse_headers/1
  , nats_headers_from_msg_opts/1
  , crash/1
  , kv_get_value/3
  , kv_list_keys/2
  , unix_seconds/0
  , kv_select_history/3
]).

getenv(Key) when is_binary(Key) ->
    case os:getenv(binary_to_list(Key)) of
        false -> nil;
        Value -> list_to_binary(Value)
    end;
getenv(Key) when is_list(Key) ->
    case os:getenv(Key) of
        false -> nil;
        Value -> list_to_binary(Value)
    end.

ensure_all_started(App) when is_atom(App) ->
    application:ensure_all_started(App);
ensure_all_started(App) when is_binary(App) ->
    application:ensure_all_started(binary_to_atom(App, utf8)).

recv_any(TimeoutMs) when is_integer(TimeoutMs), TimeoutMs >= 0 ->
    receive
        Any -> {ok, Any}
    after TimeoutMs ->
        {error, timeout}
    end.

send_any(Pid, Msg) when is_pid(Pid) ->
    Pid ! Msg,
    ok.

json_decode(JsonBin) ->
    try
        {ok, jiffy:decode(JsonBin, [return_maps])}
    catch
        Class:Reason ->
            {error, {Class, Reason}}
    end.

json_encode(Term) ->
    try
        {ok, jiffy:encode(Term)}
    catch
        Class:Reason ->
            {error, {Class, Reason}}
    end.

base64url_encode(Bin) ->
    Enc = base64:encode(Bin),
    %% base64url: replace and strip padding
    Enc1 = binary:replace(Enc, <<"+">>, <<"-">>, [global]),
    Enc2 = binary:replace(Enc1, <<"/">>, <<"_">>, [global]),
    binary:replace(Enc2, <<"=">>, <<>>, [global]).

base64url_decode(Bin0) when is_binary(Bin0) ->
    %% add padding back
    PadLen = (4 - (byte_size(Bin0) rem 4)) rem 4,
    Padding =
        case PadLen of
            0 -> <<>>;
            1 -> <<"=">>;
            2 -> <<"==">>;
            3 -> <<"===">>
        end,
    Bin1 = <<Bin0/binary, Padding/binary>>,
    Bin2 = binary:replace(Bin1, <<"-">>, <<"+">>, [global]),
    Bin3 = binary:replace(Bin2, <<"_">>, <<"/">>, [global]),
    try
        {ok, base64:decode(Bin3)}
    catch
        Class:Reason ->
            {error, {Class, Reason}}
    end.

hmac_sha512(Key, Data) ->
    %% crypto:mac/4 exists on modern OTP; returns binary
    crypto:mac(hmac, sha512, Key, Data).

sha512(Data) ->
    crypto:hash(sha512, Data).

nats_parse_headers(HeaderBin) when is_binary(HeaderBin) ->
    %% HeaderBin looks like:
    %% <<"NATS/1.0 200\r\nKey: Value\r\n...\r\n\r\n">>
    %% We strip the status line and parse the remaining headers.
    case binary:split(HeaderBin, <<"\r\n">>, [global]) of
        [_Status | Rest] ->
            Data = iolist_to_binary([R, <<"\r\n">> || R <- Rest]),
            nats_hd:parse_headers(Data);
        _ ->
            []
    end.

nats_headers_from_msg_opts(MsgOpts) when is_map(MsgOpts) ->
    %% MsgOpts may contain `header => <<"...">>` (a binary).
    case maps:get(header, MsgOpts, undefined) of
        H when is_binary(H) ->
            [{binary_to_list(K), binary_to_list(V)} || {K, V} <- nats_parse_headers(H)];
        _ ->
            []
    end;
nats_headers_from_msg_opts(_) ->
    [].

crash(Message) ->
    erlang:error({jst_server_crash, Message}).

kv_list_keys(Conn, Bucket) ->
    %% Return {ok, [KeyBin]} or {error, Reason}
    case nats_kv:list_keys(Conn, Bucket, #{}, #{}) of
        {ok, Keys} when is_list(Keys) ->
            {ok, [iolist_to_binary(K) || K <- Keys]};
        Other ->
            {error, Other}
    end.

kv_get_value(Conn, Bucket, Key) ->
    %% Return {ok, ValueBin, RevInt} | deleted | not_found | {error, Reason}
    case nats_kv:get(Conn, Bucket, Key) of
        {ok, #{message := #{data := Data, seq := Seq}}} ->
            {ok, iolist_to_binary(Data), Seq};
        {deleted, _} ->
            deleted;
        {error, #{err_code := 10037}} ->
            not_found;
        {error, _} = Err ->
            Err;
        Other ->
            {error, Other}
    end.

unix_seconds() ->
    erlang:system_time(second).

kv_select_history(Conn, Bucket, Key) ->
    %% Returns all historical values for a single key (best-effort).
    %% Uses a temporary watcher under the hood (see nats_kv:select_keys/5).
    WatchOpts = #{include_history => true, headers_only => false},
    Opts = #{return_meta => false},
    case nats_kv:select_keys(Conn, Bucket, iolist_to_binary(Key), WatchOpts, Opts) of
        {ok, List} ->
            %% List contains {KeyBin, DataBin} pairs when headers_only=false and return_meta=false.
            Values = [iolist_to_binary(Data) || {_K, Data} <- List],
            {ok, Values};
        Other ->
            {error, Other}
    end.

find_static_dir() ->
    %% Try to find the repo-level `build/` directory by walking upwards from
    %% current working directory. We look for `build/jst_lustre.min.mjs`.
    %% Returns `nil` if not found.
    case file:get_cwd() of
        {ok, Cwd} ->
            case find_static_dir_from(Cwd, 0) of
                nil -> find_static_dir_from_code();
                Found -> Found
            end;
        _ ->
            find_static_dir_from_code()
    end.

find_static_dir_from_code() ->
    %% Fall back to deriving repo root from the compiled beam path.
    %% code:which(jst_server) typically returns:
    %%   .../jst_server/build/dev/erlang/jst_server/ebin/jst_server.beam
    %% From there, walk up 7 levels to reach the repo root and then look for
    %% `build/jst_lustre.min.mjs`.
    case code:which(jst_server) of
        Path when is_list(Path) ->
            Dir0 = filename:dirname(Path),
            Root = up(Dir0, 7),
            find_static_dir_from(Root, 0);
        _ ->
            nil
    end.

up(Dir, 0) -> Dir;
up(Dir, N) when N > 0 ->
    Parent = filename:dirname(Dir),
    case Parent =:= Dir of
        true -> Dir;
        false -> up(Parent, N - 1)
    end.

find_static_dir_from(_Dir, N) when N >= 10 ->
    nil;
find_static_dir_from(Dir, N) ->
    Candidate = filename:join([Dir, "build"]),
    Marker = filename:join([Candidate, "jst_lustre.min.mjs"]),
    case filelib:is_regular(Marker) of
        true -> list_to_binary(Candidate);
        false ->
            Parent = filename:dirname(Dir),
            case Parent =:= Dir of
                true -> nil;
                false -> find_static_dir_from(Parent, N + 1)
            end
    end.


