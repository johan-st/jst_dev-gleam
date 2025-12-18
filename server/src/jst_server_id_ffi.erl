%% Random ID helpers for Gleam.

-module(jst_server_id_ffi).

-export([random_hex/1, random_short_code/1]).

random_hex(Bytes) when is_integer(Bytes), Bytes > 0 ->
  Bin = crypto:strong_rand_bytes(Bytes),
  Hex = binary:encode_hex(Bin, lowercase),
  Hex.

%% Base36-ish short code using lowercase hex, length N
random_short_code(Length) when is_integer(Length), Length > 0 ->
  Bin = crypto:strong_rand_bytes(Length),
  Hex = binary:encode_hex(Bin, lowercase),
  binary:part(Hex, 0, Length).
