pub type RemoteData(a, err) {
  NotInitialized
  Pending
  Loaded(a)
  Optimistic(a)
  Errored(err)
}

pub fn map(
  data data: RemoteData(a, err),
  with update_fn: fn(a) -> a,
) -> RemoteData(a, err) {
  case data {
    Loaded(a) -> Loaded(update_fn(a))
    Optimistic(a) -> Optimistic(update_fn(a))
    _ -> data
  }
}

pub fn to_loaded(remote_data: RemoteData(a, err)) -> RemoteData(a, err) {
  case remote_data {
    Optimistic(a) -> Loaded(a)
    _ -> remote_data
  }
}

pub fn to_optimistic(remote_data: RemoteData(a, err)) -> RemoteData(a, err) {
  case remote_data {
    Loaded(a) -> Optimistic(a)
    _ -> remote_data
  }
}
