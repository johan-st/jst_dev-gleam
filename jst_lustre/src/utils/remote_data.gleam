import birl
import gleam/option.{type Option, None, Some}

pub type RemoteData(a, err) {
  NotInitialized
  Pending(optimistic: Option(a), initialized_at: birl.Time)
  Loaded(data: a, initialized_at: birl.Time, got_at: birl.Time)
  Errored(error: err, initialized_at: birl.Time)
}

pub fn data(remote_data: RemoteData(a, err)) -> Option(a) {
  case remote_data {
    Loaded(data, _, _) -> Some(data)
    Pending(optimistic, _) -> optimistic
    _ -> None
  }
}

pub fn older_than(
  remote_data: RemoteData(a, err),
  threshold_millis: Int,
) -> Bool {
  let now = birl.now()
  case remote_data {
    Loaded(_, initialized_at, _) ->
      birl.to_unix_milli(now) - birl.to_unix_milli(initialized_at)
      > threshold_millis
    Pending(_, initialized_at) ->
      birl.to_unix_milli(now) - birl.to_unix_milli(initialized_at)
      > threshold_millis
    _ -> False
  }
}

pub fn map(rd: RemoteData(a, err), f: fn(a) -> b) -> RemoteData(b, err) {
  case rd {
    Loaded(data, initialized_at, got_at) ->
      Loaded(f(data), initialized_at, got_at)
    Pending(optimistic_data, initialized_at) ->
      Pending(optimistic_data |> option.map(f), initialized_at)
    NotInitialized -> NotInitialized
    Errored(error, initialized_at) -> Errored(error, initialized_at)
  }
}

pub fn to_pending(
  from: RemoteData(a, err),
  optimistic_data: Option(a),
) -> RemoteData(a, err) {
  case from {
    NotInitialized -> Pending(optimistic_data, birl.now())
    Pending(pending, initialized_at) -> Pending(pending, initialized_at)
    Loaded(data, _, _) -> {
      case optimistic_data {
        Some(optimistic_data) -> Pending(Some(optimistic_data), birl.now())
        None -> Pending(Some(data), birl.now())
      }
    }
    Errored(_, _) -> Pending(None, birl.now())
  }
}

pub fn to_loaded(from: RemoteData(a, err), data: a) -> RemoteData(a, err) {
  case from {
    Pending(_, initialized_at) -> Loaded(data, initialized_at, birl.now())
    Loaded(_, _, _) -> from
    Errored(_, initialized_at) -> Loaded(data, initialized_at, birl.now())
    NotInitialized -> Loaded(data, birl.now(), birl.now())
  }
}

pub fn to_errored(from: RemoteData(a, err), error: err) -> RemoteData(a, err) {
  let init = case from {
    Pending(_, t) -> t
    Loaded(_, t, _) -> t
    Errored(_, t) -> t
    NotInitialized -> birl.now()
  }
  Errored(error, init)
}
