%% Env var helpers for Gleam.

-module(jst_server_env_ffi).

-export([must_env/1, get_env/2]).

must_env(NameBin) when is_binary(NameBin) ->
  case os:getenv(binary_to_list(NameBin)) of
    false -> erlang:error({missing_env, NameBin});
    ValueList -> unicode:characters_to_binary(ValueList)
  end.

get_env(NameBin, DefaultBin) when is_binary(NameBin), is_binary(DefaultBin) ->
  case os:getenv(binary_to_list(NameBin)) of
    false -> DefaultBin;
    ValueList -> unicode:characters_to_binary(ValueList)
  end.
