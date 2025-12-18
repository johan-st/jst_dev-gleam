-module(jst_server_file_ffi).
-export([read_file/1]).

read_file(Path) ->
    case file:read_file(Path) of
        {ok, Binary} -> {ok, Binary};
        {error, _Reason} -> {error, nil}
    end.

