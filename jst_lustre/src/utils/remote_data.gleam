pub type RemoteData(a, err) {
  NotInitialized
  Pending
  Loaded(a)
  Errored(err)
}

pub fn try_update(
  remote_data: RemoteData(a, err),
  update: fn(a) -> a,
) -> RemoteData(a, err) {
  case remote_data {
    Loaded(a) -> Loaded(update(a))
    _ -> remote_data
  }
}
